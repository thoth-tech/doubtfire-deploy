require File.expand_path('../boot', __FILE__)
require 'rails/all'
require 'csv'
require 'yaml'
require 'bunny-pub-sub/services_manager'

# Precompile assets before deploying to production
if defined?(Bundler)
Bundler.require(*Rails.groups(assets: %w(development test)))
end

module Doubtfire
class Application < Rails::Application
# Load application defaults
config.load_defaults 7.0

# Load environment variables from .env
Dotenv::Railtie.load

# Authentication Method
# Default is database; can be overridden with DF_AUTH_METHOD (database, ldap, aaf, saml)
config.auth_method = (ENV['DF_AUTH_METHOD'] || :database).to_sym

# Student Work Directory
# Directory to store student files; defaults to "student_work" under root
config.student_work_dir = ENV['DF_STUDENT_WORK_DIR'] || "#{Rails.root}/student_work"

# Institution Settings
# Load YAML settings with environment variable overrides
config.institution = YAML.load_file("#{Rails.root}/config/institution.yml").with_indifferent_access
config.institution[:name] = ENV['DF_INSTITUTION_NAME'] if ENV['DF_INSTITUTION_NAME']
config.institution[:email_domain] = ENV['DF_INSTITUTION_EMAIL_DOMAIN'] if ENV['DF_INSTITUTION_EMAIL_DOMAIN']
config.institution[:host] = ENV['DF_INSTITUTION_HOST'] if ENV['DF_INSTITUTION_HOST']
config.institution[:product_name] = ENV['DF_INSTITUTION_PRODUCT_NAME'] if ENV['DF_INSTITUTION_PRODUCT_NAME']
config.institution[:privacy] = ENV['DF_INSTITUTION_PRIVACY'] if ENV['DF_INSTITUTION_PRIVACY']
config.institution[:plagiarism] = ENV['DF_INSTITUTION_PLAGIARISM'] if ENV['DF_INSTITUTION_PLAGIARISM']

# Host configuration for development environment
config.institution[:host] = 'localhost:3000' if Rails.env.development?
config.institution[:host_url] = Rails.env.development? ? "http://#{config.institution[:host]}/" : "https://#{config.institution[:host]}/"

# Load additional institution settings file if specified
config.institution[:settings] = ENV['DF_INSTITUTION_SETTINGS_RB'] if ENV['DF_INSTITUTION_SETTINGS_RB']
config.institution[:ffmpeg] = ENV['DF_FFMPEG_PATH'] || 'ffmpeg'
require "#{Rails.root}/config/#{config.institution[:settings]}" unless config.institution[:settings].nil?

# SAML2.0 Authentication
if config.auth_method == :saml
config.saml = HashWithIndifferentAccess.new
config.saml[:SAML_metadata_url] = ENV['DF_SAML_METADATA_URL']
config.saml[:assertion_consumer_service_url] = ENV['DF_SAML_CONSUMER_SERVICE_URL']
config.saml[:entity_id] = ENV['DF_SAML_SP_ENTITY_ID']
config.saml[:idp_sso_target_url] = ENV['DF_SAML_IDP_TARGET_URL']
config.saml[:idp_sso_signout_url] = ENV['DF_SAML_IDP_SIGNOUT_URL']

# Load certificate and name identifier format if no metadata URL is provided
if config.saml[:SAML_metadata_url].nil?
config.saml[:idp_sso_cert] = ENV['DF_SAML_IDP_CERT']
config.saml[:idp_name_identifier_format] = ENV['DF_SAML_IDP_SAML_NAME_IDENTIFIER_FORMAT'] || "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress"
end

# Validate required SAML environment variables
if config.saml[:assertion_consumer_service_url].nil? || config.saml[:entity_id].nil? || config.saml[:idp_sso_target_url].nil?
raise "Invalid values specified to SAML, check environment variables."
end

# Ensure IDP certificate is provided if no metadata URL exists
if config.saml[:SAML_metadata_url].nil? && config.saml[:idp_sso_cert].nil?
raise "Missing IDP certificate for SAML configuration."
end
end

# AAF Authentication
if config.auth_method == :aaf
config.aaf = HashWithIndifferentAccess.new
config.aaf[:issuer_url] = ENV['DF_AAF_ISSUER_URL'] || 'https://rapid.test.aaf.edu.au'
config.aaf[:audience_url] = ENV['DF_AAF_AUDIENCE_URL']
config.aaf[:callback_url] = ENV['DF_AAF_CALLBACK_URL']
config.aaf[:redirect_url] = ENV['DF_AAF_UNIQUE_URL']
config.aaf[:identity_provider_url] = ENV['DF_AAF_IDENTITY_PROVIDER_URL']
config.aaf[:auth_signout_url] = ENV['DF_AAF_AUTH_SIGNOUT_URL']
config.aaf[:redirect_url] += "?entityID=#{config.aaf[:identity_provider_url]}"

# Validate required AAF environment variables
if config.aaf[:audience_url].nil? || config.aaf[:callback_url].nil? || config.aaf[:redirect_url].nil? || config.aaf[:identity_provider_url].nil?
raise "Invalid values specified to AAF, check environment variables."
end
end

# Secret Key Validation
if secrets.secret_key_base.nil? || secrets.secret_key_attr.nil? || secrets.secret_key_devise.nil?
raise "Required keys are not set, check environment variables."
end

# ActiveRecord Connection Handling
config.active_record.legacy_connection_handling = false

# Localization
config.i18n.enforce_available_locales = true

# Filter sensitive parameters from logs
config.filter_parameters += %i(auth_token password password_confirmation)

# Eager Load Paths
config.eager_load_paths << Rails.root.join('app') << Rails.root.join('app', 'models', 'comments')

# Old CORS Configuration
config.middleware.insert_before Warden::Manager, Rack::Cors do
allow do
origins '*'
resource '*', headers: :any, methods: %i(get post put delete options)
end
end

# Updated CORS Security Patch Fix
config.middleware.insert_before Warden::Manager, Rack::Cors do
allow do
origins ENV['DF_ALLOWED_ORIGINS'].split(',')
resource '*', headers: :any, methods: %i(get post put delete options)
end
end

# Generators Configuration for Test Framework
if Rails.env.test?
config.generators do |g|
g.test_framework :minitest,
fixtures: true,
view_specs: false,
helper_specs: false,
routing_specs: false,
controller_specs: true,
request_specs: true
end
end

# Overseer Configuration
config.sm_instance = nil
config.overseer_enabled = ENV['OVERSEER_ENABLED'].present?

if config.overseer_enabled
config.overseer_images = YAML.load_file(Rails.root.join('config/overseer-images.yml')).with_indifferent_access
config.sm_instance = ServicesManager.instance
config.sm_instance.register_client(:ontrack, publisher_config, subscriber_config)
end
end
end
