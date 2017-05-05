module CapEC2
  class EC2Handler
    include CapEC2::Utils

    def initialize
      load_config
      configured_regions = get_regions(fetch(:ec2_region))
      @ec2 = {}
      configured_regions.each do |region|
        @ec2[region] = ec2_connect(region)
      end
    end

    def ec2_connect(region=nil)
      Aws.config.update({
        credentials: Aws::Credentials.new(fetch(:ec2_access_key_id) || ENV.fetch('AWS_ACCESS_KEY_ID'), fetch(:ec2_secret_access_key) || ENV.fetch('AWS_SECRET_ACCESS_KEY'))
      })

      return Aws::EC2::Resource.new(region: region)
    end

    def status_table
      CapEC2::StatusTable.new(
        defined_roles.map {|r| get_servers_for_role(r)}.flatten.uniq {|i| i.instance_id}
      )
    end

    def server_names
      puts defined_roles.map {|r| get_servers_for_role(r)}
                   .flatten
                   .uniq {|i| i.instance_id}
                   .map {|i| i.tags["Name"]}
                   .join("\n")
    end

    def instance_ids
      puts defined_roles.map {|r| get_servers_for_role(r)}
                   .flatten
                   .uniq {|i| i.instance_id}
                   .map {|i| i.instance_id}
                   .join("\n")
    end

    def defined_roles
      roles(:all).flat_map(&:roles_array).uniq.sort
    end

    def stage
      Capistrano::Configuration.env.fetch(:stage).to_s
    end

    def application
      fetch(:ec2_application) || Capistrano::Configuration.env.fetch(:application).to_s
    end

    def tag(tag_name)
      "tag:#{tag_name}"
    end

    def get_servers_for_role(role)
      servers = []

      filters = [
        {
          name: tag(project_tag),
          values: ["*#{application}*"]
        },
        {
          name: 'instance-state-name',
          values: ['running']
        },
      ]

      @ec2.each do |_, ec2|
        ec2.instances({ filters: filters }).each do |i|
          instance_has_tag?(i, roles_tag, role) &&
            instance_has_tag?(i, stages_tag, stage) &&
            instance_has_tag?(i, project_tag, application) &&
            (fetch(:ec2_filter_by_status_ok?) ? instance_status_ok?(i) : true) &&
            servers << i
        end
      end

      servers.flatten.sort_by {|s| s.tags.select{|tag| tag.key == "Name"}.first.value || ''}
    end

    def get_server(instance_id)
      @ec2.each do |region, ec2|
        return ec2.instances({instance_ids: [instance_id]}).first
      end
    end

    private

    def instance_has_tag?(instance, key, value)
      instance.tags.select{|tag| tag.key == key}.first != nil or return false
      
      (instance.tags.select{|tag| tag.key == key}.first.value || '').split(',').map(&:strip).include?(value.to_s)
    end

    def instance_status_ok?(instance)
      @ec2.any? do |_, ec2|
        response = ec2.client.describe_instance_status(
          instance_ids: [instance.id],
          filters: [{ name: 'instance-status.status', values: %w(ok) }]
        )
        response.data.has_key?(:instance_status_set) && response.data[:instance_status_set].any?
      end
    end
  end
end
