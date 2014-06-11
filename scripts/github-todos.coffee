# Configuration:
#   HUBOT_GITHUB_TODOS_REPO
#   HUBOT_GITHUB_TOKEN
#   HUBOT_GITHUB_USER_<NAME>
#   HUBOT_GITHUB_USER_<NAME>_TOKEN
#
# Notes:
#   HUBOT_GITHUB_TODOS_REPO = 'username/reponame' (separate multiple with commas, first one is primary)
#   HUBOT_GITHUB_TOKEN = oauth token (we use a "dobthubot" github account)
#   HUBOT_GITHUB_USER_ADAM = 'adamjacobbecker'
#   HUBOT_GITHUB_USER_ADAM_TOKEN = adamjacobbecker's oauth token
#
#   Individual users' oauth tokens are opt-in, but if you choose
#   not to add them, you'll end up notifying yourself when you
#   add a task.
#
#   You'll need to create 'done', 'trash', 'upcoming', 'shelf', and 'current' labels.
#
# Commands:
#   hubot add task <text> #todos
#   hubot ask <user|everyone> to <text> #todos
#   hubot assign <id> to <user> #todos
#   hubot assign <user> to <id> #todos
#   hubot finish <id> #todos
#   hubot finish <id> <text> #todos
#   hubot i'll work on <id> #todos
#   hubot move <id> to <done|current|upcoming|shelf> #todos
#   hubot what am i working on #todos
#   hubot what's <user|everyone> working on #todos
#   hubot what's next #todos
#   hubot what's next for <user|everyone> #todos
#   hubot what's on <user|everyone>'s shelf #todos
#   hubot what's on my shelf #todos
#   hubot work on <id> #todos
#   hubot work on <text> #todos
#   hubot show milestones #todos
#   hubot show milestones for <repo> #todos
#
# License:
#   MIT

_  = require 'underscore'
_s = require 'underscore.string'
async = require 'async'
moment = require 'moment'

log = (msgs...) ->
  console.log(msgs)

doubleUnquote = (x) ->
  _s.unquote(_s.unquote(x), "'")

class GithubTodosSender

  @ISSUE_BODY_SEPARATOR = ' body:'

  constructor: (robot) ->
    @robot = robot
    @github = require("githubot")(@robot)
    @allRepos = (process.env['HUBOT_GITHUB_TODOS_REPO'] || '').split(',') # default to empty string for tests
    @primaryRepo = @allRepos[0]

  getGithubUser: (userName) ->
    log "Getting GitHub username for #{userName}"
    process.env["HUBOT_GITHUB_USER_#{userName.split(' ')[0].toUpperCase()}"]

  getGithubToken: (userName) ->
    log "Getting GitHub token for #{userName}"
    process.env["HUBOT_GITHUB_USER_#{userName.split(' ')[0].toUpperCase()}_TOKEN"]

  optionsFor: (msg) ->
    options = {}

    if (x = @getGithubToken(msg.message.user.name))
      options.token = x

    options

  getIssueText: (issue, opts = {}) ->
    str = "#{opts.prefix || ''}"

    if opts.includeAssignee
      str += "#{issue.assignee?.login} - "

    if !issue.url.match(@primaryRepo)
      str += "#{issue.url.split('repos/')[1].split('/issues')[0]} "

    str += "##{issue.number} #{issue.title} - #{issue.html_url}"

    str

  getMilestoneText: (milestone, opts = {}) ->
    repoName = milestone.url.split('repos/')[1].split('/milestones')[0]
    milestoneIssuesUrl = "https://github.com/#{repoName}/issues?milestone=#{milestone.number}&state=open"
    dueDateText = if milestone.due_on then moment(milestone.due_on).fromNow(true) else "No due date"

    """
      #{repoName} #{milestone.title} - #{dueDateText} - #{milestoneIssuesUrl}
    """

  addIssueEveryone: (msg, issueBody, opts) ->
    userNames = {}

    for k, v of process.env
      if (x = k.match(/^HUBOT_GITHUB_USER_(\S+)$/)?[1]) && (k != "HUBOT_GITHUB_USER_#{msg.message.user.name.split(' ')[0].toUpperCase()}")
        userNames[x] = v unless x.match(/hubot/i) or x.match(/token/i) or (v in _.values(userNames))

    for userName in _.keys(userNames)
      @addIssue(msg, issueBody, userName, opts)

  addIssue: (msg, issueBody, userName, opts = {}) ->
    if userName.toLowerCase() in ['all', 'everyone']
      return @addIssueEveryone(msg, issueBody, opts)

    [title, body] = doubleUnquote(issueBody)
                    .replace(/\"/g, '')
                    .split(GithubTodosSender.ISSUE_BODY_SEPARATOR)

    sendData =
      title: title
      body: body || ''
      assignee: @getGithubUser(userName)
      labels: [opts.label || 'upcoming']

    if opts.footer && _.isEmpty(@optionsFor(msg))
      sendData.body += "\n\n(added by #{@getGithubUser(msg.message.user.name) || 'unknown user'}. " +
                   "remember, you'll need to bring them in with an @mention.)"

    log "Adding issue", sendData

    @github.withOptions(@optionsFor(msg)).post "repos/#{@primaryRepo}/issues", sendData, (data) =>
      msg.send @getIssueText(data, prefix: "Added: ")

  moveIssue: (msg, issueId, newLabel, opts = {}) ->
    @github.get "repos/#{@primaryRepo}/issues/#{issueId}", (data) =>
      labelNames = _.pluck(data.labels, 'name')
      labelNames = _.without(labelNames, 'done', 'trash', 'upcoming', 'shelf', 'current')
      labelNames.push(newLabel.toLowerCase())

      sendData =
        state: if newLabel in ['done', 'trash'] then 'closed' else 'open'
        labels: labelNames

      log "Moving issue", sendData

      @github.withOptions(@optionsFor(msg)).patch "repos/#{@primaryRepo}/issues/#{issueId}", sendData, (data) =>
        if _.find(data.labels, ((l) -> l.name.toLowerCase() == newLabel.toLowerCase()))
          msg.send @getIssueText(data, prefix: "Moved to #{newLabel.toLowerCase()}: ")

  commentOnIssue: (msg, issueId, body, opts = {}) ->
    sendData =
      body: body

    log "Commenting on issue", sendData

    @github.withOptions(@optionsFor(msg)).post "repos/#{@primaryRepo}/issues/#{issueId}/comments", sendData, (data) ->
      # Nada

  assignIssue: (msg, issueId, userName, opts = {}) ->
    sendData =
      assignee: @getGithubUser(userName)

    log "Assigning issue", sendData

    @github.withOptions(@optionsFor(msg)).patch "repos/#{@primaryRepo}/issues/#{issueId}", sendData, (data) =>
      msg.send @getIssueText(data, prefix: "Assigned to #{data.assignee.login}: ")

  showIssues: (msg, userName, label) ->
    queryParams =
      assignee: if userName.toLowerCase() == 'everyone' then '*' else @getGithubUser(userName)
      labels: label

    log "Showing issues", queryParams

    showIssueFunctions = []

    for repo in @allRepos
      do (repo) =>
        showIssueFunctions.push( (cb) =>
          @github.get "repos/#{repo}/issues", queryParams, (data) ->
            cb(null, data)
        )

    async.parallel showIssueFunctions, (err, results) =>
      log("ERROR: #{err}") if err
      allResults = [].concat.apply([], results)

      if _.isEmpty allResults
          msg.send "No issues found."
      else
        msg.send _.map(allResults, ((issue) => @getIssueText(issue, { includeAssignee: queryParams.assignee == '*' }))).join("\n")

  showMilestones: (msg, repoName) ->
    queryParams =
      state: 'open'

    log "Showing milestones", queryParams

    showMilestoneFunctions = []

    selectedRepos = if repoName == 'all'
      @allRepos
    else
      _.filter @allRepos, (repo) ->
        repo.split('/')[1].match(repoName)

    for repo in selectedRepos
      do (repo) =>
        showMilestoneFunctions.push( (cb) =>
          @github.get "repos/#{repo}/milestones", queryParams, (data) ->
            cb(null, data)
        )

    async.parallel showMilestoneFunctions, (err, results) =>
      log("ERROR: #{err}") if err
      allResults = [].concat.apply([], results)

      allResults = _.sortBy allResults, (r) ->
        r.due_on || "9"

      if _.isEmpty allResults
          msg.send "No milestones found."
      else
        msg.send _.map(allResults, ((milestone) => @getMilestoneText(milestone))).join("\n")

module.exports = (robot) ->
  robot.githubTodosSender = new GithubTodosSender(robot)

  robot.respond /add task (.*)/i, (msg) ->
    robot.githubTodosSender.addIssue msg, msg.match[1], msg.message.user.name

  robot.respond /work on ([A-Z\'\"][\s\S\d]+)/i, (msg) ->
    robot.githubTodosSender.addIssue msg, msg.match[1], msg.message.user.name, label: 'current', footer: true

  robot.respond /ask (\S+) to (.*)/i, (msg) ->
    robot.githubTodosSender.addIssue msg, msg.match[2], msg.match[1], footer: true

  robot.respond /move\s(task\s)?\#?(\d+) to (\S+)/i, (msg) ->
    robot.githubTodosSender.moveIssue msg, msg.match[2], msg.match[3]

  robot.respond /finish\s(task\s)?\#?(\d+)/i, (msg) ->
    if (comment = msg.message.text.split(GithubTodosSender.ISSUE_BODY_SEPARATOR)[1])
      robot.githubTodosSender.commentOnIssue msg, msg.match[2], doubleUnquote(_s.trim(comment))

    robot.githubTodosSender.moveIssue msg, msg.match[2], 'done'

  robot.respond /work on\s(task\s)?\#?(\d+)/i, (msg) ->
    robot.githubTodosSender.moveIssue msg, msg.match[2], 'current'

  robot.respond /what am i working on\??/i, (msg) ->
    robot.githubTodosSender.showIssues msg, msg.message.user.name, 'current'

  robot.respond /what(['|’]s|s|\sis) (\S+) working on\??/i, (msg) ->
    robot.githubTodosSender.showIssues msg, msg.match[2], 'current'

  robot.respond /what(['|’]s|s|\sis) next for (\S+)\??/i, (msg) ->
    robot.githubTodosSender.showIssues msg, msg.match[2].replace('?', ''), 'upcoming'

  robot.respond /what(['|’]s|s|\sis) next\??(\s*)$/i, (msg) ->
    robot.githubTodosSender.showIssues msg, msg.message.user.name, 'upcoming'

  robot.respond /what(['|’]s|s|\sis) on my shelf\??/i, (msg) ->
    robot.githubTodosSender.showIssues msg, msg.message.user.name, 'shelf'

  robot.respond /what(['|’]s|s|\sis) on (\S+) shelf\??/i, (msg) ->
    robot.githubTodosSender.showIssues msg, msg.match[2].split('\'')[0], 'shelf'

  robot.respond /assign \#?(\d+) to (\S+)/i, (msg) ->
    robot.githubTodosSender.assignIssue msg, msg.match[1], msg.match[2]

  robot.respond /assign (\S+) to \#?(\d+)/i, (msg) ->
    robot.githubTodosSender.assignIssue msg, msg.match[2], msg.match[1]

  robot.respond /i(['|’]ll|ll) work on \#?(\d+)/i, (msg) ->
    robot.githubTodosSender.assignIssue msg, msg.match[2], msg.message.user.name

  robot.respond /show milestones for (\S+)/i, (msg) ->
    robot.githubTodosSender.showMilestones msg, msg.match[1]

  robot.respond /show milestones(\s*)$/i, (msg) ->
    robot.githubTodosSender.showMilestones msg, 'all'

