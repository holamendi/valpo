require "sinatra/base"
require "sequel"
require "json"

class AcceptanceApp < Sinatra::Base
  set :host_authorization, {permitted_hosts: []}
  DB = Sequel.connect(ENV.fetch("DATABASE_URL"))
  DB.create_table?(:acceptance_items) { String :value, primary_key: true }

  get("/health") { DB.get(Sequel.lit("1")).to_s }
  get("/items") {
    content_type :json
    JSON.generate(DB[:acceptance_items].select_map(:value))
  }
  post("/items/:value") {
    DB[:acceptance_items].insert_conflict.insert(value: params.fetch("value"))
    status 201
  }
end
run AcceptanceApp
