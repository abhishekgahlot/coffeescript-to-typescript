# CoffeeScript can be used both on the server, as a command-line compiler based
# on Node.js/V8, or to run CoffeeScript directly in the browser. This module
# contains the main entry functions for tokenizing, parsing, and compiling
# source CoffeeScript into JavaScript.

{Lexer}       = require './lexer'
{parser}      = require './parser'
{toSAST}      = require './transformer'
helpers       = require './helpers'
SourceMap     = require './sourcemap'

{setTranslatingFile} = require './helpers'

# The current CoffeeScript version number.
exports.VERSION = '1.6.3'

extensions = ['.coffee', '.litcoffee', '.coffee.md']

# Expose helpers for testing.
exports.helpers = helpers

# Compile CoffeeScript code to JavaScript, using the Coffee/Jison compiler.
#
# If `options.sourceMap` is specified, then `options.filename` must also be specified.  All
# options that can be passed to `SourceMap#generate` may also be passed here.
#
# This returns a javascript string, unless `options.sourceMap` is passed,
# in which case this returns a `{js, v3SourceMap, sourceMap}`
# object, where sourceMap is a sourcemap.coffee#SourceMap object, handy for doing programatic
# lookups.
exports.compile = compile = (code, options = {}) ->
  {merge} = helpers

  if options.sourceMap
    map = new SourceMap

  lexemes = lexer.tokenize code
  ast = parser.parse(lexemes, options)
  sast = toSAST(ast)
  fragments = sast.compileToFragments options

  # sanity check; very useful for debugging compiler
  for fragment in fragments
    if fragment.constructor.name != 'CodeFragment'
      console.log "Internal Type Error: expected code fragment, found"
      console.log "    #{fragment.constructor.name}:", fragment, "\n"
      foundNonFragment = yes
  process.exit(1) if foundNonFragment

  currentLine = 0
  currentLine += 1 if options.header
  currentLine += 1 if options.shiftLine
  currentColumn = 0
  js = ""
  for fragment in fragments
    # Update the sourcemap with data from each fragment
    if options.sourceMap
      l = fragment.locationData
      if l and l.first_line and l.last_line and l.first_column and l.last_column
        map.add(
          [fragment.locationData.first_line, fragment.locationData.first_column]
          [currentLine, currentColumn]
          {noReplace: true})
      newLines = helpers.count fragment.code, "\n"
      currentLine += newLines
      currentColumn = fragment.code.length - (if newLines then fragment.code.lastIndexOf "\n" else 0)

    # Copy the code from each fragment into the final JavaScript.
    js += fragment.code

  if options.header
    header = "Generated by CoffeeScript #{@VERSION}"
    js = "// #{header}\n#{js}"

  # TODO Dirty dirty
  js = js.replace /return \s*var \s*(\w+) \s*=\s*(.+?);/, 'return $2;'

  if options.sourceMap
    answer = {js}
    answer.sourceMap = map
    answer.v3SourceMap = map.generate(options, code)
    answer.sourceMapHash = map.generateHash(options, code)
    answer
  else
    js

# Tokenize a string of CoffeeScript code, and return the array of tokens.
exports.tokens = (code, options) ->
  lexer.tokenize code, options

# Parse a string of CoffeeScript code or an array of lexed tokens, and
# return the AST. You can then compile it by calling `.compile()` on the root,
# or traverse it by using `.traverseChildren()` with a callback.
exports.nodes = (source, options) ->
  if typeof source is 'string'
    parser.parse lexer.tokenize source, options
  else
    parser.parse source

# Instantiate a Lexer for our use here.
lexer = new Lexer

# The real Lexer produces a generic stream of tokens. This object provides a
# thin wrapper around it, compatible with the Jison API. We can then pass it
# directly as a "Jison lexer".
parser.lexer =
  lex: ->
    token = @tokens[@pos++]
    if token
      [tag, @yytext, @yylloc] = token
      @yylineno = @yylloc.first_line
    else
      tag = ''

    tag
  setInput: (@tokens) ->
    @pos = 0
  upcomingInput: ->
    ""
# Make all the AST nodes visible to the parser.
parser.yy = require './nodes'

# Override Jison's default error handling function.
parser.yy.parseError = (message, {token}) ->
  # Disregard Jison's message, it contains redundant line numer information.
  throw new Error
  message = "unexpected #{if token is 1 then 'end of input' else token}"
  # The second argument has a `loc` property, which should have the location
  # data for this token. Unfortunately, Jison seems to send an outdated `loc`
  # (from the previous token), so we take the location information directly
  # from the lexer.
  helpers.throwSyntaxError message, parser.lexer.yylloc

# Based on http://v8.googlecode.com/svn/branches/bleeding_edge/src/messages.js
# Modified to handle sourceMap
formatSourcePosition = (frame, getSourceMapping) ->
  fileName = undefined
  fileLocation = ''

  if frame.isNative()
    fileLocation = "native"
  else
    if frame.isEval()
      fileName = frame.getScriptNameOrSourceURL()
      fileLocation = "#{frame.getEvalOrigin()}, " unless fileName
    else
      fileName = frame.getFileName()

    fileName or= "<anonymous>"

    line = frame.getLineNumber()
    column = frame.getColumnNumber()

    # Check for a sourceMap position
    source = getSourceMapping fileName, line, column
    fileLocation =
      if source
        "#{fileName}:#{source[0]}:#{source[1]}"
      else
        "#{fileName}:#{line}:#{column}"

  functionName = frame.getFunctionName()
  isConstructor = frame.isConstructor()
  isMethodCall = not (frame.isToplevel() or isConstructor)

  if isMethodCall
    methodName = frame.getMethodName()
    typeName = frame.getTypeName()

    if functionName
      tp = as = ''
      if typeName and functionName.indexOf typeName
        tp = "#{typeName}."
      if methodName and functionName.indexOf(".#{methodName}") isnt functionName.length - methodName.length - 1
        as = " [as #{methodName}]"

      "#{tp}#{functionName}#{as} (#{fileLocation})"
    else
      "#{typeName}.#{methodName or '<anonymous>'} (#{fileLocation})"
  else if isConstructor
    "new #{functionName or '<anonymous>'} (#{fileLocation})"
  else if functionName
    "#{functionName} (#{fileLocation})"
  else
    fileLocation
