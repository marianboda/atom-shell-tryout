DirStore = require '../stores/DirStore'
TreeNode = require '../tree'
DB = require '../services/NeDbService'
ProcessService = require '../services/ProcessService'
Reflux = require 'reflux'

console.log 'screen SCAN INITIALIZATION ========'
console.log 'process.env.NODE_PATH', process.env.NODE_PATH

Actions = require '../actions'

Page = React.createClass
  displayName: 'SubPage'
  mixins: [Reflux.ListenerMixin]
  componentDidMount: ->
    @listenTo DirStore, -> @forceUpdate()

  buttonClickHandler: ->
    console.log 'yeah, it was clicked'
    Actions.scan()

  render: ->
    React.DOM.div {},
      React.DOM.h3 {}, 'SCAN: ' + @props.params.id
      React.createElement TreeNode,
        items: DirStore.data.get('items') #DirStore.data.get('items')
        name: DirStore.data.get('name') #DirStore.data.get('name')
      React.DOM.hr {}
      React.DOM.button {onClick: @buttonClickHandler}, 'SCAN'
      React.DOM.button {}, 'SOMETHIN ELSE'

module.exports = Page
