React = require 'react'
fs = require 'fs'
Flux = require 'flux'
Reflux = require 'reflux'
I = require 'immutable'
Q = require 'q'
file = require 'file'
Router = require 'react-router'

config = require './config'
TreeNode = require './components/Tree'
ProcessService = require './services/ProcessService'
DefPage = require './pages/Home'
ScanPage = require './pages/Scan'
dirStore = require './stores/DirStore'
Actions = require './actions'

Dispatcher = new Flux.Dispatcher()
Route = Router.Route

App = React.createClass
  displayName: 'App'
  render: ->
    console.log 'rendering App: ', location.hash
    React.DOM.div {},
      React.DOM.a {href: '#/'}, 'HOME'
      React.DOM.span {}, ' '
      React.DOM.a {href: '#/scan/33'}, 'SCAN'
      React.DOM.hr {}
      React.createElement Router.RouteHandler, React.__spread({},  this.props)

routes =
  React.createElement Route, {name: 'app', path: '/', handler: App},
    React.createElement Route, {name: 'scan', path: 'scan', handler: ScanPage},
      React.createElement Route, {name: 'detail', path: ':id', handler: ScanPage}
    React.createElement Router.DefaultRoute, {handler:DefPage}

window.onload = ->
  Router.run routes, (Handler, state) ->
    React.render React.createElement(Handler, {params: state.params}), document.body
