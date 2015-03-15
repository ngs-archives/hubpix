require('dotenv').load()
bodyParser = require('body-parser')
dateFormat = require 'dateformat'
express = require 'express'
extend = require 'extend'
github = require 'octonode'
morgan = require 'morgan'
_redis = require 'redis'
session = require 'express-session'
sassMiddleware = require 'node-sass-middleware'
connectCoffeeScript = require 'connect-coffee-script'
Path = require 'path'
Promise = require 'promise'
RedisStore = require('connect-redis') session
parseLinkHeader = require 'parse-link-header'

if uriString = process.env.REDISTOGO_URL || process.env.BOXEN_REDIS_URL
  uri = require('url').parse uriString
  redis = _redis.createClient uri.port, uri.hostname
  redis.auth uri.auth?.split(':')?[1]
else
  redis = _redis.createClient()

app = express()
app.set 'view engine', 'jade'
app.set 'views', __dirname + '/views'
app.use session {
  secret: process.env.SESSION_SECRET || '<insecure>'
  store: new RedisStore client: redis
  resave: yes
  saveUninitialized: yes
}
app.use bodyParser.json()
app.use bodyParser.urlencoded extended: yes
app.use morgan 'combined'
app.use sassMiddleware {
  src: "#{__dirname}/frontend/sass"
  dest: "#{__dirname}/public"
  debug: process.env.NODE_ENV isnt 'production'
}
app.use connectCoffeeScript {
  src: "#{__dirname}/frontend/coffee"
  dest: "#{__dirname}/public"
}
app.use express.static Path.join __dirname, 'public'
app.locals.endpoints = (try JSON.parse process.env.IMAGE_ENDPOINTS) || {}

app.use (req, res, next) ->
  if req.headers['x-forwarded-proto'] is 'http'
    res.redirect "https://#{req.host}#{req.path}"
    return
  if /^\/(login|oauth\/callbacks)$/.test req.path
    do next
    return
  app.getCurrentUser(req)
    .done ({user, client}) ->
      req.user = user
      req.client = client
      do next
    , (err) ->
      res.render 'login', req

app.getCurrentUser = (req) ->
  new Promise (fulfill, reject) ->
    unless token = req.session.token
      reject new Error 'Not logged in'
      return
    client = github.client token
    client.me().info (e, b) ->
      if e?
        reject e
      else
        fulfill { user: b, client }

app.renderError = (res, message, status = 403) ->
  res.status(status).render 'error', message: message

app.get '/oauth/callbacks', (req, res) ->
  {authState, authReturnUrl} = req.session
  {state, code} = req.query
  req.session.authState = null
  req.session.authReturnUrl = null
  if authState && state && authState isnt state
    app.renderError res, 'Invalid state'
    return
  github.auth.login code, (err, token) ->
    if err
      console.error err
      app.renderError res, err.message, 400
      return
    req.session.token = token
    res.redirect 302, authReturnUrl || '/'

app.get '/login', (req, res) ->
  {returnUrl} = req.query
  try
    authUrl = github.auth.config(
      id: process.env.GITHUB_CLIENT_ID
      secret: process.env.GITHUB_CLIENT_SECRET
    ).login ['user', 'repo', 'org']
    state = authUrl.match(/&state=([0-9a-z]{32})/i)?[1]
    req.session.authState = state
    req.session.authReturnUrl = returnUrl
    res.redirect 302, authUrl
  catch e
    app.renderError res, e.message, 400

for route in [
  '/orgs/:org/:repo/:branch/:path/upload'
  '/orgs/:org/:repo/:branch/upload'
  '/:user/:repo/:branch/:path/upload'
  '/:user/:repo/:branch/upload'
]
  app.get route, (req, res) -> res.render 'upload', req

for route in [
  '/orgs/:org/:repo/:branch'
  '/orgs/:org/:repo'
  '/orgs/:org'
  '/:user/:repo/:branch'
  '/:user/:repo'
  '/:user'
  '/'
]
  app.get route, (req, res) -> res.render 'index', req


app.get '/:user/:repo/:branch/:path/upload', (req, res) ->
  res.render 'upload', req

app.listen process.env.PORT || 3000

