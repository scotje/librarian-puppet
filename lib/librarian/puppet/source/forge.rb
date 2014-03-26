require 'json'
require 'open-uri'

module Librarian
  module Puppet
    module Source
      class Forge
        include Librarian::Puppet::Util

        class Repo
          include Librarian::Puppet::Util

          attr_accessor :source, :name
          private :source=, :name=

          def initialize(source, name)
            self.source = source
            self.name = name
            # API returned data for this module including all versions and dependencies, indexed by module name
            # from http://forge.puppetlabs.com/api/v1/releases.json?module=#{name}
            @api_data = nil
            # API returned data for this module and a specific version, indexed by version
            # from http://forge.puppetlabs.com/api/v1/releases.json?module=#{name}&version=#{version}
            @api_version_data = {}
          end

          def versions
            return @versions if @versions
            @versions = api_data(name).map { |r| r['version'] }.reverse
            if @versions.empty?
              info { "No versions found for module #{name}" }
            else
              debug { "  Module #{name} found versions: #{@versions.join(", ")}" }
            end
            @versions
          end

          def dependencies(version)
            api_version_data(name, version)['dependencies']
          end

          def manifests
            versions.map do |version|
              Manifest.new(source, name, version)
            end
          end

          def install_version!(version, install_path)
            if environment.local? && !vendored?(name, version)
              raise Error, "Could not find a local copy of #{name} at #{version}."
            end

            if environment.vendor?
              vendor_cache(name, version) unless vendored?(name, version)
            end

            cache_version_unpacked! version

            if install_path.exist?
              install_path.rmtree
            end

            unpacked_path = version_unpacked_cache_path(version).join(name.split('/').last)

            unless unpacked_path.exist?
              raise Error, "#{unpacked_path} does not exist, something went wrong. Try removing it manually"
            else
              cp_r(unpacked_path, install_path)
            end

          end

          def environment
            source.environment
          end

          def cache_path
            @cache_path ||= source.cache_path.join(name)
          end

          def version_unpacked_cache_path(version)
            cache_path.join('version').join(hexdigest(version.to_s))
          end

          def hexdigest(value)
            Digest::MD5.hexdigest(value)
          end

          def cache_version_unpacked!(version)
            path = version_unpacked_cache_path(version)
            return if path.directory?

            # The puppet module command is only available from puppet versions >= 2.7.13
            #
            # Specifying the version in the gemspec would force people to upgrade puppet while it's still usable for git
            # So we do some more clever checking
            #
            # Executing older versions or via puppet-module tool gives an exit status = 0 .
            #
            check_puppet_module_options

            path.mkpath

            target = vendored?(name, version) ? vendored_path(name, version) : name

            # Newer versions of PMT expect to communicate directly with Forge API.
            repo = (pmt_uses_v3? && (source =~ /forge\.puppetlabs\.com/i)) ? 'https://forgeapi.puppetlabs.com' : source


            command = "puppet module install --version #{version} --target-dir '#{path}' --module_repository '#{repo}' --modulepath '#{path}' --module_working_dir '#{path}' --ignore-dependencies '#{target}'"
            debug { "Executing puppet module install for #{name} #{version}" }
            output = `#{command}`

            # Check for bad exit code
            unless $? == 0
              # Rollback the directory if the puppet module had an error
              path.unlink
              raise Error, "Error executing puppet module install:\n#{command}\nError:\n#{output}"
            end

          end

          def check_puppet_module_options
            min_version    = Gem::Version.create('2.7.13')
            puppet_version = Gem::Version.create(PUPPET_VERSION.gsub('-', '.'))

            if puppet_version < min_version
              raise Error, "To get modules from the forge, we use the puppet faces module command. For this you need at least puppet version 2.7.13 and you have #{puppet_version}"
            end
          end

          def pmt_uses_v3?
            if defined?(PE_VERSION) && !PE_VERSION.nil?
              min_version = Gem::Version.create('3.2.0')
              pe_version = Gem::Version.create(PE_VERSION)

              return pe_version >= min_version
            end

            # TODO: Future versions of open source Puppet module tool will also
            # use v3 API, checks for that version snould be made here.

            return false
          end

          def vendored?(name, version)
            vendored_path(name, version).exist?
          end

          def vendored_path(name, version)
            environment.vendor_cache.join("#{name.sub("/", "-")}-#{version}.tar.gz")
          end

          def vendor_cache(name, version)
            info = api_version_data(name, version)
            url = "#{source}#{info[name].first['file']}"
            path = vendored_path(name, version).to_s
            debug { "Downloading #{url} into #{path}"}
            File.open(path, 'wb') do |f|
              open(url, "rb") do |input|
                f.write(input.read)
              end
            end
          end

        private

          # get and cache the API data for a specific module with all its versions and dependencies
          def api_data(module_name)
            return @api_data[module_name] if @api_data
            # call API and cache data
            @api_data = api_call(module_name)
            if @api_data.nil?
              raise Error, "Unable to find module '#{name}' on #{source}"
            end
            @api_data[module_name]
          end

          # get and cache the API data for a specific module and version
          def api_version_data(module_name, version)
            # if we already got all the versions, find in cached data
            return @api_data[module_name].detect{|x| x['version'] == version.to_s} if @api_data
            # otherwise call the api for this version if not cached already
            @api_version_data[version] = api_call(name, version) if @api_version_data[version].nil?
            @api_version_data[version]
          end

          def api_call(module_name, version=nil)
            base_url = source.uri
            path = "api/v1/releases.json?module=#{module_name}"
            path = "#{path}&version=#{version}" unless version.nil?
            url = "#{base_url}/#{path}"
            debug { "Querying Forge API for module #{name}#{" and version #{version}" unless version.nil?}: #{url}" }

            begin
              data = open(url) {|f| f.read}
              JSON.parse(data)
            rescue OpenURI::HTTPError => e
              case e.io.status[0].to_i
              when 404,410
                nil
              else
                raise e, "Error requesting #{base_url}/#{path}: #{e.to_s}"
              end
            end
          end
        end

        class << self
          LOCK_NAME = 'FORGE'

          def lock_name
            LOCK_NAME
          end

          def from_lock_options(environment, options)
            new(environment, options[:remote], options.reject { |k, v| k == :remote })
          end

          def from_spec_args(environment, uri, options)
            recognised_options = []
            unrecognised_options = options.keys - recognised_options
            unless unrecognised_options.empty?
              raise Error, "unrecognised options: #{unrecognised_options.join(", ")}"
            end

            new(environment, uri, options)
          end
        end

        attr_accessor :environment
        private :environment=
        attr_reader :uri

        def initialize(environment, uri, options = {})
          self.environment = environment
          @uri = uri
          @cache_path = nil
        end

        def to_s
          uri
        end

        def ==(other)
          other &&
          self.class == other.class &&
          self.uri == other.uri
        end

        alias :eql? :==

        def hash
          self.to_s.hash
        end

        def to_spec_args
          [uri, {}]
        end

        def to_lock_options
          {:remote => uri}
        end

        def pinned?
          false
        end

        def unpin!
        end

        def install!(manifest)
          manifest.source == self or raise ArgumentError

          name = manifest.name
          version = manifest.version
          install_path = install_path(name)
          repo = repo(name)

          repo.install_version! version, install_path
        end

        def manifest(name, version, dependencies)
          manifest = Manifest.new(self, name)
          manifest.version = version
          manifest.dependencies = dependencies
          manifest
        end

        def cache_path
          @cache_path ||= begin
            dir = Digest::MD5.hexdigest(uri)
            environment.cache_path.join("source/puppet/forge/#{dir}")
          end
        end

        def install_path(name)
          environment.install_path.join(name.split('/').last)
        end

        def fetch_version(name, version_uri)
          versions = repo(name).versions
          if versions.include? version_uri
            version_uri
          else
            versions.first
          end
        end

        def fetch_dependencies(name, version, version_uri)
          repo(name).dependencies(version).map do |k, v|
            v = Requirement.new(v).gem_requirement
            Dependency.new(k, v, nil)
          end
        end

        def manifests(name)
          repo(name).manifests
        end

      private

        def repo(name)
          @repo ||= {}
          @repo[name] ||= Repo.new(self, name)
        end
      end
    end
  end
end
