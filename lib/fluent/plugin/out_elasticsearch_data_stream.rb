require_relative 'out_elasticsearch'

module Fluent::Plugin
  class ElasticsearchOutputDataStream < ElasticsearchOutput

    Fluent::Plugin.register_output('elasticsearch_data_stream', self)

    helpers :event_emitter

    config_param :data_stream_name, :string

    INVALID_START_CHRACTERS = ["-", "_", "+", "."]
    INVALID_CHARACTERS = ["\\", "/", "*", "?", "\"", "<", ">", "|", " ", ",", "#", ":"]

    def configure(conf)
      super

      # ref. https://www.elastic.co/guide/en/elasticsearch/reference/master/indices-create-data-stream.html
      unless valid_data_stream_name?
        unless start_with_valid_characters?
          if not_dots?
            raise Fluent::ConfigError, "'data_stream_name' must not start with #{INVALID_START_CHRACTERS.join(",")}: <#{@data_stream_name}>"
          else
            raise Fluent::ConfigError, "'data_stream_name' must not be . or ..: <#{@data_stream_name}>"
          end
        end
        unless valid_characters?
          raise Fluent::ConfigError, "'data_stream_name' must not contain invalid characters #{INVALID_CHARACTERS.join(",")}: <#{@data_stream_name}>"
        end
        unless lowercase_only?
          raise Fluent::ConfigError, "'data_stream_name' must be lowercase only: <#{@data_stream_name}>"
        end
        if @data_stream_name.bytes.size > 255
          raise Fluent::ConfigError, "'data_stream_name' must not be longer than 255 bytes: <#{@data_stream_name}>"
        end
      end

      begin
        require 'elasticsearch/xpack'
      rescue LoadError
        raise Fluent::ConfigError, "'elasticsearch/xpack'' is required for <@elasticsearch_data_stream>."
      end

      begin
        @client = client
        create_ilm_policy
        create_index_template
        create_data_stream
      rescue => e
        raise Fluent::ConfigError, "Failed to create data stream: <#{@data_stream_name}> #{e.message}"
      end
    end

    def create_ilm_policy
      params = {
        policy_id: "#{@data_stream_name}_policy",
        body: File.read(File.join(File.dirname(__FILE__), "default-ilm-policy.json"))
      }
      @client.xpack.ilm.put_policy(params)
    end

    def create_index_template
      body = {
        "index_patterns" => ["#{@data_stream_name}*"],
        "data_stream" => {},
        "template" => {
          "settings" => {
            "index.lifecycle.name" => "#{@data_stream_name}_policy"
          }
        }
      }
      params = {
        name: @data_stream_name,
        body: body
      }
      @client.indices.put_index_template(params)
    end

    def create_data_stream
      params = {
        "name": @data_stream_name,
      }
      begin
        response = @client.indices.get_data_stream(params)
        unless response.is_a?(Elasticsearch::Transport::Transport::Errors::NotFound)
          log.info "Specified data stream exists: <#{@data_stream_name}>"
          return
        end
      rescue Elasticsearch::Transport::Transport::Errors::NotFound => e
        log.info "Specified data stream does not exist. Will be created: <#{e}>"
      end
      @client.indices.create_data_stream(params)
    end

    def valid_data_stream_name?
      lowercase_only? and
        valid_characters? and
        start_with_valid_characters? and
        not_dots? and
        @data_stream_name.bytes.size <= 255
    end

    def lowercase_only?
      @data_stream_name.downcase == @data_stream_name
    end

    def valid_characters?
      not (INVALID_CHARACTERS.each.any? do |v| @data_stream_name.include?(v) end)
    end

    def start_with_valid_characters?
      not (INVALID_START_CHRACTERS.each.any? do |v| @data_stream_name.start_with?(v) end)
    end

    def not_dots?
      not (@data_stream_name == "." or @data_stream_name == "..")
    end

    def client_library_version
      Elasticsearch::VERSION
    end

    def multi_workers_ready?
      true
    end

    def write(chunk)
      bulk_message = ""
      headers = {
        CREATE_OP => {}
      }
      tag = chunk.metadata.tag
      chunk.msgpack_each do |time, record|
        next unless record.is_a? Hash

        begin
          record.merge!({"@timestamp" => Time.at(time).iso8601(@time_precision)})
          bulk_message = append_record_to_messages(CREATE_OP, {}, headers, record, bulk_message)
        rescue => e
          router.emit_error_event(tag, time, record, e)
        end
      end

      params = {
        index: @data_stream_name,
        body: bulk_message
      }
      begin
        response = @client.bulk(params)
        if response['errors']
          log.error "Could not bulk insert to Data Stream: #{@data_stream_name} #{response}"
        end
      rescue => e
        log.error "Could not bulk insert to Data Stream: #{@data_stream_name} #{e.message}"
      end
    end

    def append_record_to_messages(op, meta, header, record, msgs)
      header[CREATE_OP] = meta
      msgs << @dump_proc.call(header) << BODY_DELIMITER
      msgs << @dump_proc.call(record) << BODY_DELIMITER
      msgs
    end

    def retry_stream_retryable?
      @buffer.storable?
    end
  end
end