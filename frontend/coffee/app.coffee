API_BASE = 'https://api.github.com'

is_iOS = /^Mozilla\/\d\.\d\s\(iP(hone|ad|od\stouch);\sCPU/.test navigator.userAgent

getAccessToken = -> $('meta[name=x-github-access-token]').attr 'content'

getAPI = (path, callback) ->
  cb = (data, status, jqXHR) ->
    nextPage = jqXHR.getResponseHeader('Link')?.match(/<([^>]+)>;\s*rel="next"/)?[1]
    callback data, nextPage?
    $.getJSON nextPage, cb if nextPage?
  $.getJSON API_BASE + path, cb

createListItem = (text, link = null, image = null) ->
  link ||= '/' + text
  imgTag = if image? then """<img src="#{image}">""" else ''
  $("""<a href="#{link}" class="list-group-item">#{imgTag}#{text}</a>""").appendTo '.list-group'

organizationIndex = (path) ->
  getAPI '/user', ({login, avatar_url}) ->
    createListItem login, null, avatar_url
    getAPI '/user/orgs', (res) ->
      $.each res, (i, {login, avatar_url}) ->
        createListItem login, '/orgs/' + login, avatar_url

repositoryIndex = (path) ->
  path = if path.indexOf('/orgs/') == 0 then "#{path}" else "/users#{path}"
  getAPI "#{path}/repos?type=owner", (res, hasMore) ->
    $.each res, (i, repo) ->
      if repo.permissions.push
        path = "#{repo.owner.login}/#{repo.name}"
        prefix = if repo.owner.type is 'Organization' then '/orgs/' else '/'
        createListItem path, prefix + path

branchIndex = (path) ->
  getAPI "/repos#{path.replace /^\/orgs/, ''}/branches", (res, hasMore) ->
    $.each res, (i, {name}) ->
      createListItem name, "#{path}/#{encodeURIComponent name}"

directoryIndex = (currentPath) ->
  getAPI currentPath.replace(/^\/(?:orgs\/)?/, '/repos/').replace(/([^\/]+)$/, "git/refs/heads/$1"), ({ object: {url} }) ->
    path = $("<a href='#{url}'>")[0].pathname.replace('/git/commits/', '/git/trees/') + '?recursive=1'
    getAPI path, ({tree}) ->
      createListItem '/', currentPath + '/upload'
      $.each tree, (i, item) ->
        {type, path} = item
        if type is 'tree'
          createListItem '/' + path, "#{currentPath}/#{encodeURIComponent path}/upload"

uploader = (currentPath) ->
  imgCounts = {}
  pathComponents = currentPath.replace(/^\/(orgs\/)?/, '').split '/'
  pathComponents.pop()
  [user, repo, ref, path] = pathComponents
  ref = decodeURIComponent ref
  refAPIPath = "/repos/#{user}/#{repo}/git/refs/heads/#{ref}"
  endpoint = $('body').data('endpoints')?[currentPath] || ''
  browsingPath = decodeURIComponent path || ''
  apiBase = "#{API_BASE}/repos/#{user}/#{repo}/git/"
  action = apiBase + 'blobs'
  createTreeAPI = apiBase + 'trees'
  createCommitAPI = apiBase + 'commits'
  updateRefAPI = API_BASE + refAPIPath
  dz = null
  defaultMessage = if is_iOS
    'Select file from album'
  else
    'Drop files here to upload'
  $('#file-upload').dropzone
    dictDefaultMessage: '<i class="glyphicon glyphicon-cloud-upload"></i><br>' + defaultMessage
    addRemoveLinks: yes
    acceptedFiles: 'image/png,image/jpeg,image/gif'
    addedfile: (file) ->
      ts = new Date().toLocaleString().replace(/\//g, '-').replace(/:/g, '.')
      if imgCounts[ts]
        ts += ' ' + imgCounts[ts]
      imgCounts[ts] ||= 0
      imgCounts[ts]++
      file.name ||= "Pasted image #{ts}.png"
      if is_iOS
        file.__defineGetter__ 'name', -> "Mobile upload #{ts}.jpg"
      Dropzone.prototype.defaultOptions.addedfile.apply @, [file]
    init: ->
      dz = @
      dz.uploadFiles = (droppedFiles) ->
        shas = []
        files = [].concat droppedFiles
        do uploadNext = ->
          unless files.length > 0
            dz._finished droppedFiles, shas, null
            return
          file = files.pop()
          name = file.name
          reader = new FileReader()
          reader.onloadend = =>
            dz.emit "uploadprogress", file, 20, 10
            action = dz.element.action
            content = reader.result.replace /^data:[^;]+;base64,/, ''
            $.ajax({
              url: action
              method: 'POST'
              data: JSON.stringify { content, encoding: 'base64' }
            })
            .done ({sha}) ->
              dz.emit "uploadprogress", file, 100, 10
              shas.push sha
              $(file.previewElement).attr 'data-sha', sha
              uploadNext()
            , (xhr, status, err) ->
              dz._errorProcessing files, err?.message || dz.options.dictResponseError.replace("{{statusCode}}", xhr.status), xhr
          reader.readAsDataURL file
        no

  $('#file-upload').attr({action})
    .on 'submit', ->
      form = $ @
      input = form.find 'input[type=text]'
      input.prop 'disabled', yes
      btn = form.find 'button[type=submit]'
      btn.button('commiting').prop 'disabled', yes
      message = input.val()
      newTree = $('.dz-preview.dz-complete').map ->
        ele = $ @
        sha = ele.data 'sha'
        path = (ele.find('[data-dz-name]').text() || new Date().getTime() + Math.ceil(Math.random() * 10000000) + '.png')
        path = browsingPath + '/' + path if browsingPath
        { sha, path, mode: '100644', type: 'blob' }
      .get()
      getAPI refAPIPath, ({object}) ->
        parentCommit = object.sha
        $.getJSON object.url, (res) ->
          {tree} = res
          base_tree = tree.sha
          tree = newTree
          params = { base_tree, tree }
          $.post createTreeAPI, JSON.stringify(params), (res) ->
            params = { parents: [parentCommit], tree: res.sha, message }
            $.post createCommitAPI, JSON.stringify(params), (res) ->
              params = { sha: res.sha }
              $.ajax({ url: updateRefAPI, method: 'PATCH', data: JSON.stringify(params) }).done (res) ->
                dz.removeAllFiles()
                input.prop 'disabled', no
                btn.button('reset').prop 'disabled', no
                setTimeout refreshThumbnails, 1000
      no
  $(document).on 'paste', (e) ->
    dz?.paste e.originalEvent

  do refreshThumbnails = ->
    getAPI "/repos/#{user}/#{repo}/contents/#{browsingPath}?ref=#{ref}&_ts=#{new Date().getTime()}", (res) ->
      $('.current-items').empty()
      res = res.filter ({ path }) -> /\.(png|jpg|gif)$/.test path
      row = null
      $.each res, (i, item) ->
        if i % 4 == 0
          row = $('<div class="row">').appendTo '.current-items'
        row.append """
        <div class="col-sm-6 col-md-3">
          <div class="thumbnail">
            <a href="#{item.html_url}" target="_blank">
              <img src="#{item.download_url}" style="max-width:100%" alt="#{item.name}">
            </a>
            <div class="caption">
              <p><b>#{item.name}</b></p>
              <p><input class="form-control" type="text" value="![#{item.name}](#{endpoint}#{encodeURIComponent item.name})" onclick="this.select()" readonly></p>
            </div>
          </div>
        </div>
        """

routes =
  '/': [organizationIndex, 'Select organization']
  '/:user': [repositoryIndex, 'Select repository']
  '/:user/:repo': [branchIndex, 'Select branch']
  '/:user/:repo/:branch': [directoryIndex, 'Select directory to upload']
  '/:user/:repo/:branch/upload': [uploader, 'Upload']
  '/:user/:repo/:branch/:path/upload': [uploader, 'Upload']
  '/orgs/:org': [repositoryIndex, 'Select repository']
  '/orgs/:org/:repo': [branchIndex, 'Select branch']
  '/orgs/:org/:repo/:branch': [directoryIndex, 'Select directory to upload']
  '/orgs/:org/:repo/:branch/upload': [uploader, 'Upload']
  '/orgs/:org/:repo/:branch/:path/upload': [uploader, 'Upload']

updateBreadCrumbs = (paths) ->
  ol = $ 'ol.breadcrumb'
  isUpload = no
  if paths[paths.length - 1] is 'upload'
    paths.pop()
    isUpload = yes
  last = paths.length - 1
  for i in [0..last]
    continue if paths[i] is 'orgs'
    text = if i == 0
      '<i class="glyphicon glyphicon-home"></i>'
    else
      decodeURIComponent paths[i]
    ol.append if i == last
      if isUpload && last == 4
        """
        <li><a href="#{paths[0..i].join('/') || '/'}">#{text}</a></li>
        <li class="active">(root)</li>
        """
      else
        """<li class="active">#{text}</li>"""
    else
      """<li><a href="#{paths[0..i].join('/') || '/'}">#{text}</a></li>"""

handleRoute = ->
  if route = $('meta[name=x-route-path]').attr 'content'
    [fn, title] = routes[route]
    $('.page-header h1').text title
    path = document.location.pathname
    updateBreadCrumbs path.split '/'
    fn? path

Dropzone.options.fileUpload = no

$.ajaxSettings.beforeSend = (xhr) ->
  xhr.setRequestHeader 'Authorization', "token #{getAccessToken()}"

$ ->
  do handleRoute
  $('input[type=search]').on 'keyup', (e) ->
    text = $(@).val().toUpperCase()
    $('.list-group-item').each ->
      item = $ @
      if !text || item.text().toUpperCase().indexOf(text) isnt -1
        item.show()
      else
        item.hide()

