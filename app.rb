
require 'sinatra'
require 'json'
require 'mongo'
require 'open-uri'

require 'sinatra/reloader' if development?
require 'pry' if development?

directories = %w(lib)

directories.each do |directory|
  Dir["#{File.dirname(__FILE__)}/#{directory}/*.rb"].each do |file|
    require file
  end
end

# Connect to mongo; set the collections
configure do
  set :static, false
  db = Mongo::Client.new([ '127.0.0.1:27017' ], :database => 'iiif-notifications')
  set :mongo_db, db
  set :manifests, db[:manifests]
  set :notifications, db[:notifications]
  set :logger, Logger.new(STDOUT)
end

helpers do
  # a helper method to turn a string ID
  # representation into a BSON::ObjectId
  def object_id val
    begin
      BSON::ObjectId.from_string(val)
    rescue BSON::ObjectId::Invalid
      nil
    end
  end

  def add_to_payload(doc, attribute_string, type)
    return_status = log_if_missing(doc[attribute_string], attribute_string)
    return if return_status
    data = pull_payload_attributes(doc[attribute_string], type)
    return label_for_payload(type), data
  end

  def pull_payload_attributes(uri, type)
    if open(uri).read.empty?
      logger.warn("Object #{uri} does not return JSON payload as expected")
      return
    end
    response = JSON.parse(open(uri).read)
    return fetch_payload(response, type)
  end

  def log_if_missing(attribute, attribute_label)
    if attribute.to_s.strip.empty?
      logger.warn("Missing #{attribute_label} value in notification")
      return true
    end
    return false
  end

  def fetch_payload(response, type)
    case type
      when 'sc:Range'
        return response['ranges']
      else
        return response
    end
  end

  def label_for_payload(type)
    return 'structures' if type == 'sc:Range'
  end

  def notification_value(value, value_type)
    return (value.nil? ? 'iiifsupplement' : value) if value_type == 'motivation'
    return value
  end

  def missing?(value)
    return value.nil? || value.empty?
  end

  #Can be used to validate DateTime values
  def datetime_validate(value)
    begin
      return DateTime.parse(value)
    rescue ArgumentError, NoMethodError
      logger.warn("Invalid DateTime format for #{value}")
    end
  end

  def document_by_id collection, id
    id = object_id(id) if String === id
    if id.nil?
      {}
    else
      document = settings.mongo_db[collection].find(:_id => id).to_a.first
      document || {}
    end
  end

  def remove_by_id collection, id
    return if id.nil?
    return if id === String && id.strip.empty?

    id = object_id(id) if String === id
    settings.mongo_db[collection].delete_one(_id: id)
  end
end

get '/' do
  content_type :json

  JSON.dump({})
end

##
# Static manifests
#
get '/iiif/:name.json' do |filename|
  content_type :json
  headers "Access-Control-Allow-Origin" => "*"
  send_file "public/manifests/#{filename}.json"
end

# Return the manifest with `:name`
#
# GET '/iiif/:name/manifests'
get '/iiif/:name/manifest/?' do
  headers( "Access-Control-Allow-Origin" => "*")
  content_type :json
  headers 'Link' => '</notifications>; rel="http://www.w3.org/ns/ldp#inbox"'
  at_id = "http://library.upenn.edu/iiif/#{params[:name]}/manifest"
  manifest = settings.manifests.find({'@id': at_id}).to_a.first
  manifest.delete "_id" unless manifest.nil?
  JSON.pretty_generate manifest || {}
end

# Accept a notification
# POST '/iiif/notifications'
post '/iiif/notifications' do
  headers( "Access-Control-Allow-Origin" => "*")
  return 415 unless request.content_type == 'application/json'
  content_type :json
  payload = JSON.parse(request.body.read)
  payload['received'] = DateTime.now.strftime('%d-%m-%Y %I:%M:%S %Z')
  result = settings.notifications.insert_one payload
  JSON.pretty_generate result.inserted_id
end

# GET '/iiif/notifications' # return all notfifications
# GET '/iiif/notifications?target=<URL>'
get '/iiif/notifications/?' do
  headers( "Access-Control-Allow-Origin" => "*")
  content_type :json

  protocol  = request.ssl? ? 'https': 'http'
  host_port = request.host_with_port
  path      = request.path.chomp('/')

  this_uri  = "#{protocol}://#{host_port}#{path}"

  # There's a target, find all notifications on it
  args = params[:target].nil? ? nil : {target: params[:target]}
  # this_uri = request.env['REQUEST_URI']
  data = { '@context': 'http://www.w3.org/ns/ldp' }
  data[:'@id'] = this_uri
  payload = ''
  data[:contains] = settings.notifications.find(args).map { |doc|
    attribute = 'object'
    type = 'sc:Range'
    doc['target'] = [doc['target']] unless doc['target'].respond_to? :each
    doc['target'].each do |target|
      label, payload = add_to_payload(doc, attribute, type)
      if payload.nil?
        logger.warn("Nothing in #{target} payload returned for #{attribute} #{type}, skipping update")
        next
      end
      settings.manifests.find_one_and_update({'@id' => doc['@id']}, { '$set' => {"#{label}": payload } })
    end

    contains = { url: "#{this_uri}/#{doc['_id']}",
                 motivation: "#{notification_value(doc['motivation'], 'motivation')}"
    }

    contains[:updated] = "#{notification_value(doc['updated'], 'updated')}" unless missing?(doc['updated'])
    contains[:source] = "#{notification_value(doc['source'], 'source')}" unless missing?(doc['source'])
    contains[:received] = "#{notification_value(doc['received'], 'received')}" unless missing?(doc['received'])

    contains
  }
  JSON.pretty_generate data || {}
end

get '/iiif/test' do
  headers( "Access-Control-Allow-Origin" => "*")
  content_type :json
  data = JSON.load open('./public/test_manifest.json')

  JSON.pretty_generate data
end

# Return a specific notification
#
# GET '/iiif/notifications/:id'
get '/iiif/notifications/:id' do
  headers( "Access-Control-Allow-Origin" => "*")
  content_type :json

  doc = document_by_id :notifications, params[:id]
  doc.delete :_id

  JSON.pretty_generate doc
end

delete '/iiif/notifications/:id' do
  content_type :json
  remove_by_id 'notifications', params[:id]
  JSON.generate({ ok: 1 })
end