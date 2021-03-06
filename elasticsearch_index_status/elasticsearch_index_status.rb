# Reports stats on an elasticsearch index, including index size, number of documents, etc.
#
# Created by John Wood of Signal
class ElasticsearchIndexStatus < Scout::Plugin

  OPTIONS = <<-EOS
    elasticsearch_host:
      default: http://127.0.0.1
      name: Host URL
      notes: "The URL to the host elasticsearch is running on. Include the protocal (http// or https://) in the URL."
    elasticsearch_port:
      default: 9200
      name: Port
      notes: The port elasticsearch is running on
    username:
      deault: nil
      name: Username
      notes: Username used to log into elasticsearch host if authentication is enabled.
    password:
      deault: nil
      name: Password
      notes: Password used to log into elasticsearch host if authentication is enabled.
    index_name:
      name: Index name
      notes: Name of the index you wish to monitor
  EOS

  needs 'net/http', 'net/https', 'json', 'open-uri'

  def build_report
    if option(:elasticsearch_host).nil? || option(:elasticsearch_port).nil? || option(:index_name).nil?
      return error("Please provide the host, port, and index name", "The elasticsearch host, port, and index to monitor are required.\n\nelasticsearch Host: #{option(:elasticsearch_host)}\n\nelasticsearch Port: #{option(:elasticsearch_port)}\n\nIndex Name: #{option(:index_name)}")
    end

    if option(:username).nil? != option(:password).nil?
      return error("Please provide both username and password", "Both the elasticsearch username and password to monitor the protected cluster are required.\n\nUsername: #{option(:username)}\n\nPassword: #{option(:password)}")
    end

    index_name = option(:index_name)

    base_url = "#{option(:elasticsearch_host)}:#{option(:elasticsearch_port)}/#{index_name}/_stats"

    resp = get_response(base_url)
    response = JSON.parse(resp.body)

    if response['error'] && response['error'] =~ /IndexMissingException/
      return error("No index found with the specified name", "No index could be found with the specified name.\n\nIndex Name: #{option(:index_name)}")
    end

    # support elasticsearch before and after formatting change
    indices = (response['_all'] && response['_all']['indices']) || response['indices']
    report(:primary_size => b_to_mb(indices[index_name]['primaries']['store']['size_in_bytes']) || 0)
    report(:size => b_to_mb(indices[index_name]['total']['store']['size_in_bytes']) || 0)
    report(:num_docs => indices[index_name]['primaries']['docs']['count'] || 0)
    search_metrics(indices)

  rescue OpenURI::HTTPError
    error("Stats URL not found", "Please ensure the base url for elasticsearch index stats is correct. Current URL: \n\n#{base_url}")
  rescue SocketError
    error("Hostname is invalid", "Please ensure the elasticsearch Host is correct - the host could not be found. Current URL: \n\n#{base_url}")
  rescue Errno::ECONNREFUSED
    error("Unable to connect", "Please ensure the host and port are correct. Current URL: \n\n#{base_url}")
  end

  def search_metrics(indices)
    index_name = option(:index_name)
    search_stats = indices[index_name]['primaries']['search']
    # sample
    # {"open_contexts"=>0, "query_total"=>319796, "query_time_in_millis"=>22074525, "query_current"=>0, "fetch_total"=>12014, "fetch_time_in_millis"=>698430, "fetch_current"=>0} 
    queries_before = memory("_counter_query_rate")
    query_total = search_stats['query_total']
    query_time = search_stats['query_time_in_millis']
    counter(:query_rate, query_total, :per => :second)
    last_query_time = memory("last_query_time")
    if queries_before and !last_query_time.nil?
      avg_query_time = (query_time - last_query_time)/(query_total-queries_before[:value]).to_f
      report(:query_time=>avg_query_time) if avg_query_time >= 0 # handle a reset
    end
    remember(:last_query_time,query_time)
  end

  # All of the elasticsearch methods use this same logic. If this needs an update, an update may be required in others as well.
  def get_response(base_url)
    uri = URI.parse(base_url)

    http = Net::HTTP.new(uri.host,uri.port)
    http.use_ssl = (uri.scheme == 'https')
    http.start { |h|
      req = Net::HTTP::Get.new(uri.path+"?"+uri.query.to_s)
      if !option(:username).nil? && !option(:password).nil?
        req.basic_auth option(:username), option(:password)
      end
      response = h.request(req)
    }
  end

  def b_to_mb(bytes)
    bytes && bytes.to_f / 1024 / 1024
  end

end
