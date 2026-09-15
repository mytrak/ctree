# frozen_string_literal: true

module Ctree
  module Domain
    module_function

    RESOLVER_DIR = "/etc/resolver"

    def macos?
      RUBY_PLATFORM.include?("darwin")
    end

    def apply_config_log_prefix!
      config = Config.load(Pathname.pwd)
      Log.log_prefix = config[:log_prefix]
    end

    def add(tld:)
      Log.die "ctree domain is only supported on macOS" unless macos?
      apply_config_log_prefix!
      container, conf_path, port = find_dnsmasq!

      entry = "address=/.#{tld}/127.0.0.1"
      lines = read_conf(conf_path)
      if lines.any? { |l| l.strip == entry }
        Log.info "dnsmasq already has entry for .#{tld}; skipping"
      else
        File.write(conf_path, (lines + ["#{entry}\n"]).join)
        Log.info "added #{entry} to #{conf_path}"
        restart_container(container)
      end

      write_resolver(tld, port)
    end

    def remove(tld:)
      Log.die "ctree domain is only supported on macOS" unless macos?
      apply_config_log_prefix!
      container, conf_path, _ = find_dnsmasq!

      entry = "address=/.#{tld}/127.0.0.1"
      lines = read_conf(conf_path)
      filtered = lines.reject { |l| l.strip == entry }
      if filtered.size == lines.size
        Log.info "no dnsmasq entry found for .#{tld}"
      else
        File.write(conf_path, filtered.join)
        Log.info "removed #{entry} from #{conf_path}"
        restart_container(container)
      end

      remove_resolver(tld)
    end

    def list
      Log.die "ctree domain is only supported on macOS" unless macos?
      apply_config_log_prefix!
      _, conf_path, _ = find_dnsmasq!
      lines = read_conf(conf_path)
      tlds = lines.filter_map do |line|
        m = line.strip.match(/\Aaddress=\/\.(\S+)\/127\.0\.0\.1\z/)
        m[1] if m
      end

      if tlds.empty?
        puts "no domains configured in #{conf_path}"
        return
      end

      tlds.each do |tld|
        resolver_path = File.join(RESOLVER_DIR, tld)
        status = File.exist?(resolver_path) ? "ok" : "missing"
        puts "#{tld}   (resolver: #{status})"
      end
    end

    def find_dnsmasq!
      out, _, st = Sh.capture3("docker", "ps", "--quiet", "--filter", "status=running")
      Log.die "docker not available" unless st.success?

      ids = out.lines.map(&:strip).reject(&:empty?)
      Log.die "no running containers found; is Docker running?" if ids.empty?

      ids.each do |id|
        inspect, _, ist = Sh.capture3("docker", "inspect", id,
                                      "--format",
                                      "{{.Name}}\t{{.Config.Image}}\t{{json .HostConfig.Binds}}\t{{json .HostConfig.PortBindings}}")
        next unless ist.success?

        name, image, binds_json, ports_json = inspect.strip.split("\t", 4)
        next unless image&.include?("dnsmasq")

        binds = JSON.parse(binds_json || "[]")
        conf_path = binds.filter_map { |b| b.split(":").first if b.include?("/etc/dnsmasq.conf") }.first
        Log.die "found dnsmasq container #{name} but cannot locate config file via volume mounts" unless conf_path

        ports = JSON.parse(ports_json || "{}")
        port = ports.values.flatten.first&.dig("HostPort") || "53"

        return [name.delete_prefix("/"), conf_path, port]
      end

      Log.die "no running dnsmasq container found; is traefik-dns running?"
    end

    def read_conf(path)
      File.exist?(path) ? File.readlines(path) : []
    end

    def restart_container(name)
      _, err, st = Spinner.with_spinner("restarting #{name}") do
        Sh.capture3("docker", "restart", name)
      end
      if st.success?
        Log.info "restarted #{name}"
      else
        Log.warn_ "docker restart #{name} failed: #{err.strip}"
      end
    end

    def write_resolver(tld, port)
      path = File.join(RESOLVER_DIR, tld)
      content = "nameserver 127.0.0.1\nport #{port}\n"

      if File.exist?(path) && File.read(path) == content
        Log.info "#{path} already configured; skipping"
        return
      end

      _, err, st = Sh.capture3("sudo", "tee", path, stdin_data: content)
      if st.success?
        Log.info "wrote #{path}"
      else
        Log.warn_ "could not write #{path} (#{err.strip})"
        Log.warn_ "run manually: sudo bash -c 'printf \"nameserver 127.0.0.1\\nport #{port}\\n\" > #{path}'"
      end
    end

    def remove_resolver(tld)
      path = File.join(RESOLVER_DIR, tld)
      unless File.exist?(path)
        Log.info "#{path} does not exist; skipping"
        return
      end

      _, err, st = Sh.capture3("sudo", "rm", path)
      if st.success?
        Log.info "removed #{path}"
      else
        Log.warn_ "could not remove #{path} (#{err.strip})"
        Log.warn_ "run manually: sudo rm #{path}"
      end
    end

    private_class_method :find_dnsmasq!, :read_conf, :restart_container,
                         :write_resolver, :remove_resolver, :apply_config_log_prefix!
  end
end
