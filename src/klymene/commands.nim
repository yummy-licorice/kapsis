# Klymene - Build delightful Command Line Interfaces.
# 
#   (c) 2022 George Lemon | MIT license
#       Made by Humans from OpenPeep
#       https://github.com/openpeep/klymene
#       
#       https://www.lihaoyi.com/post/BuildyourownCommandLinewithANSIescapecodes.html

{.warning[Spacing]: off.}

import std/[tables, macros, terminal, sets]

from std/sequtils import delete
from std/os import commandLineParams, sleep
from std/algorithm import sorted, SortOrder
from std/strutils import `%`, indent, spaces, join, startsWith, contains, count, split,
                              toUpperAscii, toLowerAscii

type
    KlymeneErrors = enum
        MaximumDepthSubCommand = "Maximum subcommand depth reached (3 levels)"
        ParentCommandNotFound = "Could not find a command id \"$1\""
        ConflictCommandName = "Command name \"$1\" already exists"

    ParameterType* = enum
        Key, Variant, LongFlag, ShortFlag

    ParamTuple = tuple[ptype: ParameterType, pid: string]

    Parameter* = ref object
        case ptype: ParameterType
        of Key:
            key: string
        of Variant:
            variant: seq[string]
        of LongFlag:
            flag: string
        of ShortFlag:
            sflag: string

    Value* = ref object
        value: Parameter

    CommandType* = enum
        CommandLine, CommentLine, SubCommandLine

    Command* = object
        name: string
            # Holds the raw command name
        case commandType: CommandType
        of CommandLine, SubCommandLine:
            commandName: string
                # Holds only the command name
            callbackName: string
                # Holds the callback name
            description: string
                # Command description
            args: OrderedTable[string, Parameter]
                # An `OrderedTable` holding all command arguments
        else: discard # ignore comment lines
    
    InputError = ref object
        msg: string

    Klymene* = object
        indent: int8
            # Used to indent & align comments (default 25 spaces)
        app_name: string
            ## The application name
        commands: OrderedTable[string, Command]
            ## Holds a parsable table with `Command` instances
        printable: OrderedTable[string, string]
            ## Holds the printable version of your commands
        canPrintExtras: bool
        appVersion: string
        invalidArg: string
        error: string

    KlymeneDefect = object of CatchableError
    SyntaxError = object of CatchableError

const NewLine = "\n"
let
    TokenSeparator {.compileTime.} = "---"
    InvalidVariantWithFlags {.compileTime.} = "Variant parameters cannot contain flags"
    InvalidCommandDefinition {.compileTime.} = "Invalid command definition"

include ./private/utils
include ./private/runtime

template getValue*[V: Value](val: V): any =
    ## A callable template to retrieve values from a `runCommand` proc
    # proc getValueByType(ptype: ParameterType) =
    #     result = case ptype: ParameterType
    #     of Key:
    #         key: string
    #     of Variant:
    #         variant: seq[string]
    #     of LongFlag:
    #         flag: string
    #     of ShortFlag:
    #         sflag: string

    # getValueByType(val.value)
    ## TODO

proc add[K: Klymene](cli: var K, id: string, key: int) =
    ## Add a new command separator, with or without a label
    let sepId = id & "__" & $key
    var label = if id.len != 0: "\e[1m" & id  & ":\e[0m" else: id
    cli.commands[sepId] = Command(commandType: CommentLine, name: label)

proc add[K: Klymene](cli: var K, id, cmdId, desc: string, args: seq[ParamTuple], callbackIdent: string, isSubCommand, isSeparator = false) =
    ## Add a new command to current Klymene instance. Commands are registered
    ## automatically from `commands` macro.
    if cli.commands.hasKey(id):
        raise newException(KlymeneDefect, $ConflictCommandName % [id])
    if isSubCommand:    
        cli.commands[id] = Command(commandType: SubCommandLine)
    else:
        cli.commands[id] = Command(commandType: CommandLine)
    cli.commands[id].name = id
    cli.commands[id].commandName = cmdId
    cli.commands[id].callbackName = callbackIdent
    cli.commands[id].description = desc

    if args.len != 0:
        var
            strCounter = 0      # holds params length
            strCommand: string
            hasDelimiter: bool
            countDelimiters: int8
        for k, param in pairs(args):
            if cli.commands[id].args.hasKey(param.pid):
                raise newException(KlymeneDefect, "Duplicate parameter name for \"$1\"" % [param.pid])
            cli.commands[id].args[param.pid] = Parameter(ptype: param.ptype)
            case param.ptype:
            of Variant:
                # `Variant` expose a group of params as a|b|c|d
                cli.commands[id].args[param.pid].variant.add(param.pid)
            of Key:
                # `Key` params can handle dynamic strings
                cli.commands[id].args[param.pid].key = param.pid
            of ShortFlag:
                # `ShortFlag` are optionals. Always prefixed with a single `-`
                cli.commands[id].args[param.pid].sflag = param.pid
            of LongFlag:
                # `LongFlag` are optionals. Always prefixed with double `--`
                cli.commands[id].args[param.pid].flag = param.pid

macro about*(info: untyped) =
    ## Macro for adding info and other comments above usage commands.
    ## Informations provided via `about` macro will be shown only
    ## when user press `app -h` or `app --help`
    info.expectKind nnkStmtList
    result = newNimNode(nnkStmtList)
    result.add(
        nnkVarSection.newTree(
            newIdentDefs(ident "aboutDescription", ident "string")
        ),
        nnkVarSection.newTree(
            newIdentDefs(ident "appVersion", ident "string")
        ),
    )

    for i in info:
        if i.kind == nnkStrLit:
            result.add quote do:
                add aboutDescription, `i` & NewLine
        elif i.kind == nnkCommand:
            if i[0].kind == nnkStrLit:
                i[1].expectKind nnkIntLit
                let commentLine = i[0]
                let size = i[1]
                result.add quote do:
                    add aboutDescription, indent(`commentLine`, `size`) & NewLine
            elif i[0].kind == nnkIdent:
                if i[0].eqIdent "version":
                    i[1].expectKind nnkStrLit
                    let currentAppVersion = i[1].strVal
                    result.add quote do:
                        appVersion = `currentAppVersion`
        # elif i.kind == nnkCall:
        #     i[0].expectKind nnkIdent
        #     echo i[1].kind
    result.add quote do:
        add aboutDescription, NewLine

macro settings*(generateBashScripts, useSmartHighlight: bool) = 
    ## Macro for changing your Klymene settings
    ## TODO


template handleCommandSeparator() =
    # Handle Commands Separators
    # Separators are declared using `---` token, followed by
    # either a label or an empty string (for space only separators),
    # for example:
    #   --- ""
    if tk.len == 2:
        tk[1].expectKind nnkStrLit
        var sepLit = newLit("")
        if tk[1].strVal.len != 0: # add a label to current spearator
            sepLit.strVal = tk[1].strVal
        result.add quote do:
            cli.add(`sepLit`, `tKey`)
        continue

macro commands*(tks: untyped) =
    ## Macro for creating new commands or sub-commands.
    tks.expectKind nnkStmtList
    
    # Init Klymene
    result = newStmtList(
        newVarStmt(ident "cli", newCall ident("Klymene"))
    )

    # var showDefaultLabel: bool
    var commandsConditional = newNimNode(nnkIfStmt)
    var registeredCommands: seq[string]
    var isParentCommand: bool
    for tkey, tk in pairs(tks):
        tk[0].expectKind nnkIdent
        
        # if tk[0].strVal == "$$":
        #     isParentCommand = true
        if tk[0].strVal != "$" and tk[0].strVal != TokenSeparator:
            raise newException(SyntaxError, "Invalid command missing `$` prefix")
        elif tk[0].strVal == TokenSeparator:
            handleCommandSeparator()
        
        # command identifier
        tk[1][0].expectKind nnkStrLit
        var
            newCommandId = tk[1][0]
            newCommandDesc = newNimNode(nnkStrLit)
            newCommandParams: seq[ParamTuple]
            isSubCommand: bool
            subCommandId: string
            parentCommands: seq[string]

        if newCommandId.strVal.contains("."):
            # Determine if this will be a command or a subcommand
            # by checking for dot annotations in `newCommandId` name
            # The maximum depth of a subcommand is by 3 levels.
            if count(newCommandId.strVal, '.') > 3:
                raise newException(KlymeneDefect, $MaximumDepthSubCommand % [newCommandId.strVal])
            elif newCommandId.strVal in registeredCommands:
                raise newException(KlymeneDefect, $ConflictCommandName % [newCommandId.strVal])
            parentCommands = split(newCommandId.strVal, '.')
            subCommandId = parentCommands[^1]
            parentCommands = parentCommands[0 .. ^2]
            for parentCommand in parentCommands:
                if parentCommand notin registeredCommands:
                    raise newException(KlymeneDefect, $ParentCommandNotFound % [parentCommand])
            isSubCommand = true

        # Store callback of current command in callbacks table
        let callbackFunction = newStmtList()
        let callbackIdent = getCallbackIdent()

        callbackFunction.add newDotExpr(
            ident callbackIdent,
            ident "runCommand"
        )

        commandsConditional.add(
            nnkElifBranch.newTree(
                nnkInfix.newTree(
                    ident("=="),
                    ident("commandName"),
                    newLit(callbackIdent)
                ),
                newStmtList(newCall(callbackFunction))
            )
        )

        if tk[1][1].kind == nnkStrLit:    # Parse command description
            newCommandDesc = tk[1][1]
        elif tk[1][1].kind == nnkCommand:
            # Handle commands with static parameters
            for args in tk[1][1]:
                if args.kind == nnkIdent: #
                    newCommandParams.add (ptype: Key, pid: args.strVal)
                elif args.kind == nnkStrLit:
                    newCommandDesc = args
                elif args.kind == nnkTupleConstr:
                    for a in args:
                        if a.kind == nnkStrLit:
                            if a.strVal.startsWith("--"): # Variant-type params cannot contain flags
                                raise newException(SyntaxError, InvalidVariantWithFlags)
                            newCommandParams.add (ptype: Variant, pid: a.strVal)
                        else: raise newException(SyntaxError, InvalidVariantWithFlags)
                elif args.kind == nnkBracket:
                    for a in args:
                        if a.kind == nnkCharLit:    # handle short flags based on chars
                            newCommandParams.add (ptype: ShortFlag, pid: $(char(a.intVal)))
                        elif a.kind == nnkStrLit:  # handle long flags and parameters
                            var param = a.strVal
                            var paramType = Key
                            if a.strVal.startsWith("--"):
                                param = param[2..^1]
                                paramType = LongFlag
                            newCommandParams.add (ptype: paramType, pid: param)

        # memorize the command id
        registeredCommands.add(newCommandId.strVal)
        
        # Register the new command
        result.add quote do:
            var cmdId = `newCommandId`
            var isSubCommand: bool
            if `isSubCommand` != 0:
                cmdId = `subCommandId`
                isSubCommand = true
            cli.add(
                `newCommandId`,
                cmdId,
                `newCommandDesc`,
                `newCommandParams`,
                `callbackIdent`,
                isSubCommand = isSubCommand
            )

    # TODO map command values
    result.add(
        nnkWhenStmt.newTree(
            nnkElifBranch.newTree(
                newCall(ident "declared", ident "aboutDescription"),
                newStmtList(
                    newAssignment(
                        newDotExpr(
                            ident "cli",
                            ident "canPrintExtras"
                        ),
                        ident("true")
                    )
                )
            )
        ),
        nnkWhenStmt.newTree(
            nnkElifBranch.newTree(
                newCall(ident "declared", ident "appVersion"),
                newStmtList(
                    newAssignment(
                        newDotExpr(
                            ident "cli",
                            ident "appVersion"
                        ),
                        ident "appVersion"
                    )
                )
            )
        ),
        newLetStmt(
            ident "commandName",
            newCall(
                newDotExpr(
                    ident("cli"),
                    ident("printUsage")
                )
            )
        ),
        commandsConditional
    )