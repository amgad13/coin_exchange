require 'sinatra'
require 'sinatra/reloader' if development?
require 'tilt/erubis'
require 'sinatra/content_for'
require 'chartkick'
require 'bcrypt'
require 'net/http'
require 'json'
require 'yaml'
require 'pry'
require 'timeout'

ROOT = File.expand_path('..', __FILE__)

HISTORICAL_BPI_API = 'https://api.coindesk.com/v1/bpi/historical/close.json'.freeze
CURRENT_PRICES_API = 'https://min-api.cryptocompare.com/data/' \
  'pricemulti?fsyms=BTC,ETH&tsyms=USD'.freeze

TIME_OUT_SECONDS = (ENV['RACK_ENV'] == 'test' ? 2 : 1500)

CURRENCY_NAMES = {
  btc: 'Bitcoin',
  eth: 'Ether',
  usd: 'US Dollars'
}.freeze

configure do
  enable :sessions
  set :session_secret, 'secret'
  set :erb, escape_html: true
end

helpers do
  def user_signed_in?
    session[:signin] && !timed_out?
  end

  def format_usd(num)
    whole, decimal = format('%.2f', num).split('.')
    comma_sliced = whole.reverse.scan(/\d{3}|\d+/).join(',').reverse
    '$' + comma_sliced + '.' + decimal
  end
end

before do
  @users_data = YAML.load_file(user_data_file_path)
  File.write('../session_log.yml', session.to_yaml)

  sign_user_out_if_idle
end

def parse_api(url)
  uri = URI(url)
  response = Net::HTTP.get(uri)
  JSON.parse(response)
end

def user_data_file_path
  if ENV['RACK_ENV'] == 'test'
    'test/users_data.yml'
  else
    'users_data.yml'
  end
end

def signin_validation_errors(username, password, agreed = nil)
  {
    'Please enter a username.'           => username.empty?,
    'Username must not contain spaces.'  => username.include?(' '),
    'Username too long.'                 => username.size > 30,
    "Username '#{username}' is unavailable." => @users_data.key?(username),
    'Password too short.'                => (1..3).cover?(password.size),
    'Password must contain a non-space character.' => password.strip.empty?,
    'Please accept the user agreement.'  => agreed != 'true'
  }
end

def build_error_message(errors)
  errors.select { |_, condition| condition }
        .keys
        .join('<br />')
end

def create_new_user_data(password)
  {
    password: BCrypt::Password.create(password).to_s,
    created: Time.now.to_s,
    new_user: true,
    balances: { btc: 0, eth: 0, usd: rand(8999..19999) },
    transactions: []
  }
end

def credentials_match?(username, password)
  return false unless @users_data.key?(username)

  stored_password = @users_data[username][:password]
  BCrypt::Password.new(stored_password) == password
end

def sign_user_in(username)
  session[:signin] = { username: username, time: Time.now }
end

def reset_idle_time
  session[:signin][:time] = Time.now
end

def sign_user_out
  session.delete(:signin)
end

def timed_out?
  session_idle_seconds = Time.now - session[:signin][:time]
  session_idle_seconds > TIME_OUT_SECONDS
end

def require_user_signed_in
  unless user_signed_in?
    session[:failure] ||= 'Please sign-in to continue.'
    redirect '/signin'
  end
  reset_idle_time
end

def sign_user_out_if_idle
  if session[:signin] && timed_out?
    sign_user_out
    session[:failure] = 'You have been logged out due to inactivity.'
  end
end

def usd_funded_message
  if signed_in_user_data[:new_user]
    signed_in_user_data[:new_user] = false
    update_users_data!

    usd_balance = signed_in_user_data[:balances][:usd]
    "Sign-up bonus! Your account was funded <b>+$#{usd_balance}</b>.<br />"
  end
end

def sign_in_message
  'You have successfully signed in as ' \
  "'#{session[:signin][:username]}'.<br />" \
  "#{usd_funded_message}" \
  "<em>Timestamp: #{session[:signin][:time]}.</em>"
end

def write_new_user_data!(username, password)
  @users_data[username] = create_new_user_data(password)
  update_users_data!
end

def update_users_data!
  File.write(user_data_file_path, @users_data.to_yaml)
end

def default_prices
  {'BTC'=>{'USD'=>rand(5000..8000)}, 'ETH'=>{'USD'=>rand(200..300)}}
end

def current_prices
  begin
    parse_api(CURRENT_PRICES_API)
  rescue SocketError 
    default_prices
  end
end

def signed_in_user_data
  username = session[:signin][:username]
  @users_data[username]
end

def user_usd_balance
  require_user_signed_in
  signed_in_user_data[:balances][:usd]
end

def spot_price_range(usd_amt, coin_amt, coin)
  (0.995..1.005).cover?(current_prices[coin]['USD'] / (usd_amt/coin_amt))
end

def invalid_numbers(*numbers)
  numbers.any? { |num| num < 0 || !num.is_a?(Numeric) }
end

def purchase_validation_errors(usd_amt, coin_amt, coin)
  {
    'Price adjusted. Please try again.' => !spot_price_range(usd_amt, coin_amt, coin),
    "Not enough funds to purchase #{coin_amt} #{coin}." => (usd_amt > user_usd_balance),
    'Invalid inputs. Please try again.' => invalid_numbers(usd_amt, coin_amt),
    'Minimum purchase of $1 is required.' => usd_amt < 1
  }
end

not_found do
  erb :not_found
end

get '/' do
  redirect '/dashboard' if user_signed_in?

  erb :index
end

get '/charts' do
  @historical_bpi = parse_api(HISTORICAL_BPI_API)
  @min_price, @max_price = @historical_bpi['bpi'].values.minmax

  current_prices = parse_api(CURRENT_PRICES_API)
  @current_price = current_prices['BTC']['USD']

  erb :charts
end

get '/signup' do
  erb :signup
end

post '/user/signup' do
  @username = params[:username]
  @password = params[:password]
  @agreed = params[:agreed]
  new_username = @username.strip

  errors = signin_validation_errors(new_username, @password, @agreed)

  if errors.none? { |_, condition| condition }
    write_new_user_data!(@username, @password)
    sign_user_out

    session[:success] = "You have created a new account '" \
    "#{new_username}'.<br />Please sign-in to continue."

    redirect '/signin'
  else
    session[:failure] = build_error_message(errors)
    status 422
    erb :signup
  end
end

get '/signin' do
  erb :signin
end

post '/user/signin' do
  @username = params[:username].strip
  @password = params[:password]

  if credentials_match?(@username, @password)
    sign_user_in(@username)
    session[:success] = sign_in_message

    redirect '/dashboard'
  else
    session[:failure] = 'Invalid credentials. Please try again.'
    status 422
    erb :signin
  end
end

get '/dashboard' do
  require_user_signed_in

  @portfolio = signed_in_user_data[:balances]

  @counter_values = {
    btc: current_prices['BTC']['USD'],
    eth: current_prices['ETH']['USD'],
    usd: 1
  }

  erb :dashboard
end

post '/user/signout' do
  sign_user_out
  session.delete(:failure) if session[:failure]
  redirect '/'
end

get '/buy/btc' do
  require_user_signed_in

  @current_btc_price = current_prices['BTC']['USD']
  @current_eth_price = current_prices['ETH']['USD']

  @usd_balance = user_usd_balance

  erb :buy_btc
end

post '/user/buy/btc' do
  require_user_signed_in

  @usd_amount = params[:amountusd].to_f
  @btc_amount = params[:amountbtc].to_f
  errors = purchase_validation_errors(@usd_amount, @btc_amount, 'BTC')

  if errors.none? { |_, condition| condition }
    session[:success] = "You have successfully purchased #{@btc_amount} BTC!"

    signed_in_user_data[:balances][:usd] -= @usd_amount
    signed_in_user_data[:balances][:btc] += @btc_amount
    update_users_data!

    redirect '/dashboard'
  else
    session[:failure] = build_error_message(errors)
    redirect '/buy/btc'
  end
end

get '/sell' do
  require_user_signed_in

  erb :sell
end

get '/settings' do
  require_user_signed_in

  erb :settings
end
