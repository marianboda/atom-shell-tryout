Reflux = require 'reflux'
I = require 'immutable'
Actions = require '../actions'
DB = require '../services/NeDbService'
fs = require 'fs'
async = require 'async'
Path = require 'path'
config = require '../config'
TreeUtils = require '../utils/TreeUtils'
_ = require 'lodash'

dataStore =
  scanningPaths: []
  scannedFiles: 0
  totalFiles: 0
  photos: []
  dirs: []
  dirTree: {name: 'root', items: []}
  files: 0
  selectedDir: null
  currentPhotos: []

  DB: new DB
  init: ->

    @loadScanningPaths()
    @loadPhotos()
    @loadDirs()

    @listenTo Actions.scan, @scan

    @listenTo Actions.selectDirectory, (dir) ->
      @currentPhotos = @photos.filter (item) -> item.dir is dir
      @selectedDir = dir
      @trigger()

    @listenTo Actions.addDirectoryToLibrary, (paths) ->
      newPaths = _.without(paths, @scanningPaths)
      @scanningPaths = _.uniq(@scanningPaths.concat(newPaths).sort())
      @DB.addScanningPath s for s in newPaths
      @trigger()

    @listenTo Actions.removeDirectoryFromLibrary, (path) ->
      @scanningPaths = _.without @scanningPaths, path
      @trigger()

  loadPhotos: ->
    @DB.getPhotos().then (data) =>
      console.log 'Photos in db: ', data.length
      @photos = data
      @currentPhotos = data[0..30]
      @trigger()

  loadScanningPaths: ->
    @DB.getScanningPaths().then (data) =>
      console.log 'Paths in db: ',data
      @scanningPaths = data.map (item) -> item.path
      @trigger()

  loadDirs: ->
    @DB.getDirs().then (data) =>
      console.log 'dirs in db: ', data.length

      dirTree =  TreeUtils.buildTree _.sortBy(data,'path'), null, null, 'name'

      newTree = TreeUtils.transform dirTree, (item) ->
        subCountReducer = (field) ->
          (prev, current) -> prev + (current[field] ? 0)
        sumField = (node, field, initField) ->
          reducer = subCountReducer(field)
          node.items.reduce reducer, (node[initField] ? 0)

        item.filesCount = if item.files?.length? then item.files.length else 0

        # item.count = item.items.reduce subCountReducer('count'), item.items.length
        # item.deepUnrecognizedCount = sumField 'deepUnrecognizedCount', 'unrecognizedCount'

        item.deepFilesCount = sumField item, 'deepFilesCount', 'filesCount'

      current = newTree
      current = current.items[0] until current.items.count is 0 or current.items[0].files?
      console.log current.path

      @dirTree = current
      @trigger()

  dirToDB: (dir) ->
    dbRec = {}
    for field of dir
      dbRec[field] = dir[field] unless field in ['items']
    @DB.addDir dbRec # {path: dir.path, added: new Date()}

  photoToDB: (photo) ->
    # @DB.getPhoto(photo.path + 'adf').then (data) ->
    #   return if data?
    @DB.addPhoto photo
    # console.log 'todb', photo
      # @photos.push photo

  scan: ->
    @files = 0
    @scannedFiles = 0
    console.log 'SCANNING STARTED'

    scanDir = (dir, callback) ->
      fs.readdir dir, (err, list) ->
        # console.log "#{dir} DONE!!", list

    processDir = (dirObject) =>
      path = dirObject.path
      parentPath = if dirObject.parent? then dirObject.parent.path else null
      walkQueue.push path,
        # (err, dirRecord) => @dirToDB(dirRecord)
        (err, dirRecord) =>
          if dirObject.parent?
            dirObject.parent.items.push dirRecord
          else
            @dirs.push dirRecord
      @files++

    processFile = (fileObject) =>
      @photoToDB fileObject
      # console.log '%csome file sent to process', 'color: #bada55'
      @scannedFiles++
      # @trigger({})

    walkQueue = async.queue (dirPath, callback)->
      fs.readdir dirPath, (err, files) ->
        thisDir = {path: dirPath, name: Path.basename(dirPath), files: [], items:[], unrecognizedCount: 0}
        async.each files,
          (f, callback) ->
            filePath = dirPath + Path.sep + f
            fs.lstat filePath, (err, stat) ->
              if stat.isDirectory()
                # thisDir.dirs.push f
                processDir
                  path: filePath
                  parent: thisDir
              if stat.isFile()
                if isRecognized(f)
                  thisDir.files.push f
                  processFile
                    name: f
                    dir: dirPath
                    path: filePath
                    stat: stat

                else
                  thisDir.unrecognizedCount += 1
              callback()
        , (err) ->
          callback(err, thisDir)
    ,2


    isRecognized = (item) ->
      Path.extname(item).substring(1).toLowerCase() in config.ACCEPTED_FORMATS

    isDirRelevant = (dir) ->
      return dir.deepFilesCount > 0

    processTree = (tree) ->
      processTreeNode = (oldNode, newNode) ->
        newNode.name = oldNode.name
        newNode.path = oldNode.path
        return unless oldNode.items?
        newNode.filesCount = oldNode.files.length
        newNode.deepFilesCount = oldNode.files.length
        newNode.unrecognizedFilesCount = oldNode.unrecognizedCount
        newNode.deepUnrecognizedFilesCount = oldNode.unrecognizedCount
        newNode.items = []
        for item in oldNode.items
          newSubnode = {}
          processTreeNode item, newSubnode
          newNode.deepFilesCount += newSubnode.deepFilesCount
          newNode.deepUnrecognizedFilesCount += newSubnode.deepUnrecognizedFilesCount
          if isDirRelevant(newSubnode)
            newNode.items.push newSubnode

        newNode.name += ' ' + newNode.deepFilesCount
      newTree = {}
      processTreeNode tree, newTree
      # console.log 'newTree', newTree
      newTree

    traverseTree = (node, nodeFunction, callback1) ->
      return unless node.items?

      async.each node.items, (item) ->
        if nodeFunction?
          nodeFunction item
        traverseTree item, nodeFunction
      , (err) ->
        # console.log callback1 if callback1?
        # if callback1?
          # console.log 'all Traversal done'

    walkQueue.drain = =>
      console.log "Q DONE: " + @files
      # @data = I.Map @dirs[0]
      @data = I.Map processTree(@dirs[0])
      @trigger {}
      traverseTree(@dirs[0], @dirToDB, 1)
      @trigger {}

    @scanningPaths.map (item) -> processDir {path: item}


  data: I.Map {name: '_blank', items: []}

module.exports = Reflux.createStore dataStore
