## This is a squashed copy/pasta version of docopt 0.6.5 with
## local fixes as needed to make it work.

# Copyright (C) 2015 Oleh Prypin <blaxpirit@gmail.com>
# Licensed under terms of MIT license (see LICENSE)

import strutils, macros

import nre, options, os, tables
from sequtils import deduplicate, delete, filter_it

export tables

from unicode import to_upper, to_lower

### EMBEDDED: docopt/util

template any_it(lst: typed, pred: untyped): bool =
    ## Does `pred` return true for any of the `it`s of `lst`?
    var result {.gensym.} = false
    for it {.inject.} in lst:
        if pred:
            result = true
            break
    result

template map_it(lst, typ: typed, op: untyped): untyped =
    ## Returns `seq[typ]` that contains `op` applied to each `it` of `lst`
    var result {.gensym.}: seq[typ] = @[]
    for it {.inject.} in items(lst):
        result.add(op)
    result


proc count[T](s: openarray[T], it: T): int =
    ## How many times this item appears in an array
    result = 0
    for x in s:
        if x == it:
            result += 1


proc partition(s, sep: string): tuple[left, sep, right: string] =
    ## "a+b".partition("+") == ("a", "+", "b")
    ## "a+b".partition("-") == ("a+b", "", "")
    assert sep != ""
    let pos = s.find(sep)
    if pos < 0:
        (s, "", "")
    else:
        (s.substr(0, pred(pos)), s.substr(pos, pred(pos)+sep.len), s.substr(pos+sep.len))


proc is_upper(s: string): bool =
    ## Is the string in uppercase (and there is at least one cased character)?
    let upper = unicode.to_upper(s)
    s == upper and upper != unicode.to_lower(s)


macro gen_class(body: untyped): untyped =
    ## When applied to a type block, this will generate methods
    ## that return each type's name as a string.
    for typ in body[0].children:
        var meth = "method class(self: $1): string"
        if $typ[2][0][1][0] == "RootObj":
            meth &= "{.base, gcsafe.}"
        meth &= "= \"$1\""
        body.add(parse_stmt(meth.format(typ[0])))
    body


### EMBEDDED: docopt/value

type
    ValueKind* = enum
        vkNone, ## No value
        vkBool, ## A boolean
        vkInt,  ## An integer
        vkStr,  ## A string
        vkList  ## A list of strings
    Value* = object  ## docopt variant type
        case kind*: ValueKind
          of vkNone:
            nil
          of vkBool:
            bool_v: bool
          of vkInt:
            int_v: int
          of vkStr:
            str_v: string
          of vkList:
            list_v: seq[string]


converter to_bool*(v: Value): bool =
    ## Convert a Value to bool, depending on its kind:
    ## - vkNone: false
    ## - vkBool: boolean value itself
    ## - vkInt: true if integer is not zero
    ## - vkStr: true if string is not empty
    ## - vkList: true if sequence is not empty
    case v.kind
        of vkNone: false
        of vkBool: v.bool_v
        of vkInt: v.int_v != 0
        of vkStr: v.str_v.len > 0
        of vkList: v.list_v.len > 0

proc len*(v: Value): int =
    ## Return the integer of a vkInt Value
    ## or the length of the seq of a vkList value.
    ## It is an error to use it on other kinds of Values.
    if v.kind == vkInt: v.int_v
    else: v.list_v.len

proc `@`*(v: Value): seq[string] =
    ## Return the seq of a vkList Value.
    ## It is an error to use it on other kinds of Values.
    v.list_v

proc `[]`*(v: Value, i: int): string =
    ## Return the i-th item of the seq of a vkList Value.
    ## It is an error to use it on other kinds of Values.
    v.list_v[i]

iterator items*(v: Value): string =
    ## Iterate over the seq of a vkList Value.
    ## It is an error to use it on other kinds of Values.
    for val in v.list_v:
        yield val

iterator pairs*(v: Value): tuple[key: int, val: string] =
    ## Iterate over the seq of a vkList Value, yielding ``(index, v[index])``
    ## pairs.
    ## It is an error to use it on other kinds of Values.
    for key, val in v.list_v:
        yield (key: key, val: val)

proc str(s: string): string =
    "\"" & s.replace("\"", "\\\"") & "\""

proc str[T](s: seq[T]): string =
    "[" & s.map_it(string, it.str).join(", ") & "]"

proc str(v: Value): string =
    case v.kind
        of vkNone: "nil"
        of vkStr: v.str_v.str
        of vkInt: $v.int_v
        of vkBool: $v.bool_v
        of vkList: v.list_v.str

proc `$`*(v: Value): string =
    ## Return the string of a vkStr Value,
    ## or the item of a vkList Value, if there is exactly one,
    ## or a string representation of any other kind of Value.
    if v.kind == vkStr:
        v.str_v
    elif v.kind == vkList and v.list_v.len == 1:
        v.list_v[0]
    else: v.str

proc `==`*(a, b: Value): bool {.gcsafe.} =
    a.kind == b.kind and a.str == b.str


proc val(): Value = Value(kind: vkNone)
proc val(v: bool): Value = Value(kind: vkBool, bool_v: v)
proc val(v: int): Value = Value(kind: vkInt, int_v: v)
proc val(v: string): Value = Value(kind: vkStr, str_v: v)
proc val(v: seq[string]): Value = Value(kind: vkList, list_v: v)


### EMBEDDED: docopt

type
    DocoptLanguageError* = object of Defect
        ## Error in construction of usage-message by developer.
    DocoptExit* = object of CatchableError
        ## Exit in case user invoked program with incorrect arguments.
        usage*: string

gen_class:
  type
    Pattern = ref object of RootObj
        m_name: string
        value: Value
        children: seq[Pattern]

    ChildPattern = ref object of Pattern

    ParentPattern = ref object of Pattern

    Argument = ref object of ChildPattern

    Command = ref object of Argument

    Option = ref object of ChildPattern
        short: string
        long: string
        argcount: int

    Required = ref object of ParentPattern

    Optional = ref object of ParentPattern

    AnyOptions = ref object of Optional
        ## Marker/placeholder for [options] shortcut.

    OneOrMore = ref object of ParentPattern

    Either = ref object of ParentPattern


proc argument(name: string, value = val()): Argument =
    Argument(m_name: name, value: value)

proc command(name: string, value = val(false)): Command =
    Command(m_name: name, value: value)

proc option(short, long: string = "", argcount = 0,
            value = val(false)): Option =
    assert argcount in [0, 1]
    result = Option(short: short, long: long,
                    argcount: argcount, value: value)
    if value.kind == vkBool and not value and argcount > 0:
        result.value = val()

proc required(children: varargs[Pattern]): Required =
    Required(children: @children)

proc optional(children: varargs[Pattern]): Optional =
    Optional(children: @children)

proc any_options(children: varargs[Pattern]): AnyOptions =
    AnyOptions(children: @children)

proc one_or_more(children: varargs[Pattern]): OneOrMore =
    OneOrMore(children: @children)

proc either(children: varargs[Pattern]): Either =
    Either(children: @children)


type
    MatchResult = tuple[matched: bool; left, collected: seq[Pattern]]
    SingleMatchResult = tuple[pos: int, match: Pattern]


{.warning[LockLevel]: off.}

method str(self: Pattern): string {.base, gcsafe, nosideeffect.} =
    assert false

method name(self: Pattern): string {.base, gcsafe.} =
    self.m_name
method `name=`(self: Pattern, name: string) {.base, gcsafe.} =
    self.m_name = name

proc `==`(self, other: Pattern): bool =
    if self.is_nil and other.is_nil:
        true
    elif not self.is_nil and not other.is_nil:
        self.str == other.str
    else:
        # Exactly one of the two is nil
        false

method flat(self: Pattern,
            types: varargs[string]): seq[Pattern] {.base, gcsafe.} =
    assert false

method match(self: Pattern, left: seq[Pattern],
             collected: seq[Pattern] = @[]): MatchResult {.base, gcsafe.} =
    assert false

method fix_identities(self: Pattern, uniq: seq[Pattern]) {.base, gcsafe.} =
    ## Make pattern-tree tips point to same object if they are equal.
    if self.children.len == 0:
        return
    for i, child in self.children:
        if child.children.len == 0:
            assert child in uniq
            self.children[i] = uniq[uniq.find(child)]
        else:
            child.fix_identities(uniq)

method fix_identities(self: Pattern) {.base, gcsafe.} =
    self.fix_identities(self.flat().deduplicate())

method either(self: Pattern): Either {.base, gcsafe.} =
    ## Transform pattern into an equivalent, with only top-level Either.
    # Currently the pattern will not be equivalent, but more "narrow",
    # although good enough to reason about list arguments.
    var ret: seq[seq[Pattern]] = @[]
    var groups = @[@[self]]
    while groups.len > 0:
        var children = groups[0]
        groups.delete(0)
        let classes = children.map_it(string, it.class)
        const parents = "Required Optional AnyOptions Either OneOrMore".split()
        if parents.any_it(it in classes):
            var child: Pattern
            for i, c in children:
                if c.class in parents:
                    child = c
                    children.delete(i, i)
                    break
            assert child != nil
            if child.class == "Either":
                for c in child.children:
                    groups.add(@[c] & children)
            elif child.class == "OneOrMore":
                groups.add(child.children & child.children & children)
            else:
                groups.add(child.children & children)
        else:
            ret.add children
    either(ret.map_it(Pattern, required(it)))

method fix_repeating_arguments(self: Pattern) {.base, gcsafe.} =
    ## Fix elements that should accumulate/increment values.
    var either: seq[seq[Pattern]] = @[]
    for child in self.either.children:
        either.add(@(child.children))
    for cas in either:
        for e in cas:
            if cas.count(e) <= 1:
                continue
            if e.class == "Argument" or
              e.class == "Option" and Option(e).argcount > 0:
                if e.value.kind == vkNone:
                    e.value = val(@[])
                elif e.value.kind != vkList:
                    e.value = val(($e.value).split_whitespace())
            if e.class == "Command" or
              e.class == "Option" and Option(e).argcount == 0:
                e.value = val(0)

method fix(self: Pattern) {.base, gcsafe.} =
    self.fix_identities()
    self.fix_repeating_arguments()


method str(self: ChildPattern): string =
    "$#($#, $#)".format(self.class, self.name.str, self.value.str)

method flat(self: ChildPattern, types: varargs[string]): seq[Pattern] =
    if types.len == 0 or self.class in types: @[Pattern(self)] else: @[]

method single_match(self: ChildPattern,
                    left: seq[Pattern]): SingleMatchResult {.base, gcsafe.} =
    assert false

method match(self: ChildPattern, left: seq[Pattern],
             collected: seq[Pattern] = @[]): MatchResult =
    var m: SingleMatchResult
    try:
        m = self.single_match(left)
    except ValueError:
        return (false, left, collected)
    var (pos, match) = m
    let left2 = left[0..<pos] & left[pos+1..^1]
    var same_name: seq[Pattern] = @[]
    for a in collected:
        if a.name == self.name:
            same_name.add a
    if self.value.kind in [vkInt, vkList]:
        let increment =
          if self.value.kind == vkInt: val(1)
          else:
            if match.value.kind == vkStr: val(@[$match.value])
            else: match.value
        if same_name.len == 0:
            match.value = increment
            return (true, left2, collected & @[match])
        if increment.kind == vkInt:
            same_name[0].value.int_v += increment.int_v
        else:
            same_name[0].value.list_v.add(@increment)
        return (true, left2, collected)
    return (true, left2, collected & @[match])


method str(self: ParentPattern): string =
    "$#($#)".format(self.class, self.children.str)

method flat(self: ParentPattern, types: varargs[string]): seq[Pattern] =
    if self.class in types:
        return @[Pattern(self)]
    result = @[]
    for child in self.children:
        result.add child.flat(types)


method single_match(self: Argument, left: seq[Pattern]): SingleMatchResult =
    for n, pattern in left:
        if pattern.class == "Argument":
            return (n, argument(self.name, pattern.value))
    raise new_exception(ValueError, "Not found")

method single_match(self: Command, left: seq[Pattern]): SingleMatchResult =
    for n, pattern in left:
        if pattern.class == "Argument":
            if pattern.value.kind == vkStr and $pattern.value == self.name:
                return (n, command(self.name, val(true)))
            else:
                break
    raise new_exception(ValueError, "Not found")


proc option_parse[T](
  constructor: proc(short, long: string; argcount: int; value: Value): T,
  option_description: string): T =
    var short, long: string = ""
    var argcount = 0
    var value = val(false)
    var (options, p, description) = option_description.strip().partition("  ")
    discard p
    options = options.replace(",", " ").replace("=", " ")
    for s in options.split_whitespace():
        if s.starts_with "--":
            long = s
        elif s.starts_with "-":
            short = s
        else:
            argcount = 1
    if argcount > 0:
        var m = description.find(re"(?i)\[default:\ (.*)\]")
        if m.is_some:
            value = val(m.get.captures[0])
        else:
            value = val()
    constructor(short, long, argcount, value)

method single_match(self: Option, left: seq[Pattern]): SingleMatchResult =
    for n, pattern in left:
        if self.name == pattern.name:
            return (n, pattern)
    raise new_exception(ValueError, "Not found")

method name(self: Option): string =
    if self.long != "": self.long else: self.short

method str(self: Option): string =
    "Option($#, $#, $#, $#)".format(self.short.str, self.long.str,
                                    self.argcount, self.value.str)


method match(self: Required, left: seq[Pattern],
             collected: seq[Pattern] = @[]): MatchResult =
    result = (true, left, collected)
    for pattern in self.children:
        result = pattern.match(result.left, result.collected)
        if not result.matched:
            return (false, left, collected)


method match(self: Optional, left: seq[Pattern],
             collected: seq[Pattern] = @[]): MatchResult =
    result = (true, left, collected)
    for pattern in self.children:
        result = pattern.match(result.left, result.collected)
    result.matched = true

method match(self: OneOrMore, left: seq[Pattern],
             collected: seq[Pattern] = @[]): MatchResult =
    assert self.children.len == 1
    result = (true, left, collected)
    var l2: seq[Pattern]
    var times = 0
    while result.matched:
        # could it be that something didn't match but changed l or c?
        result = self.children[0].match(result.left, result.collected)
        if result.matched:
            times += 1
        if l2 == result.left:
            break
        l2 = result.left
    if times >= 1:
        result.matched = true
    else:
        return (false, left, collected)


method match(self: Either, left: seq[Pattern],
             collected: seq[Pattern] = @[]): MatchResult =
    var found = false
    for pattern in self.children:
        let outcome = pattern.match(left, collected)
        if outcome.matched:
            if not found or outcome.left.len < result.left.len:
                result = outcome
            found = true
    if not found:
        return (false, left, collected)


type TokenStream = ref object
    tokens: seq[string]
    error: ref Exception

proc `@`(tokens: TokenStream): var seq[string] = tokens.tokens

proc token_stream(source: seq[string], error: ref Exception): TokenStream =
    TokenStream(tokens: source, error: error)
proc token_stream(source: string, error: ref Exception): TokenStream =
    token_stream(source.split_whitespace(), error)

proc current(self: TokenStream): string =
    if @self.len > 0:
        result = @self[0]

proc move(self: TokenStream): string =
    result = self.current
    @self.delete(0)


proc parse_long(tokens: TokenStream, options: var seq[Option]): seq[Pattern] =
    ## long ::= '--' chars [ ( ' ' | '=' ) chars ] ;
    let (long, eq, v) = tokens.move().partition("=")
    assert long.starts_with "--"
    var value = (if eq == "" and v == "": val() else: val(v))
    var similar = options.filter_it(it.long == long)
    var o: Option
    if tokens.error of DocoptExit and similar.len == 0:  # if no exact match
        similar = options.filter_it(it.long != "" and
                                    it.long.starts_with long)
    if similar.len > 1:  # might be simply specified ambiguously 2+ times?
        tokens.error.msg = "$# is not a unique prefix: $#?".format(
          long, similar.map_it(string, it.long).join(", "))
        raise tokens.error
    elif similar.len < 1:
        let argcount = (if eq == "=": 1 else: 0)
        o = option("", long, argcount)
        options.add o
        if tokens.error of DocoptExit:
            o = option("", long, argcount,
                       if argcount > 0: value else: val(true))
    else:
        o = option(similar[0].short, similar[0].long,
                   similar[0].argcount, similar[0].value)
        if o.argcount == 0:
            if value.kind != vkNone:
                tokens.error.msg = "$# must not have an argument".format(o.long)
                raise tokens.error
        else:
            if value.kind == vkNone:
                if tokens.current == "":
                    tokens.error.msg = "$# requires argument".format(o.long)
                    raise tokens.error
                value = val(tokens.move())
        if tokens.error of DocoptExit:
            o.value = (if value.kind != vkNone: value else: val(true))
    @[Pattern(o)]


proc parse_shorts(tokens: TokenStream, options: var seq[Option]): seq[Pattern] =
    ## shorts ::= '-' ( chars )* [ [ ' ' ] chars ] ;
    let token = tokens.move()
    assert token.starts_with("-") and not token.starts_with("--")
    var left = token.substr(1)
    result = @[]
    while left != "":
        let short = "-" & left[0]
        left = left.substr(1)
        let similar = options.filter_it(it.short == short)
        var o: Option
        if similar.len > 1:
            tokens.error.msg = "$# is specified ambiguously $# times".format(
              short, similar.len)
            raise tokens.error
        elif similar.len < 1:
            o = option(short, "", 0)
            options.add o
            if tokens.error of DocoptExit:
                o = option(short, "", 0, val(true))
        else:  # why copying is necessary here?
            o = option(short, similar[0].long,
                       similar[0].argcount, similar[0].value)
            var value = val()
            if o.argcount != 0:
                if left == "":
                    if tokens.current == "":
                        tokens.error.msg = "$# requires argument".format(short)
                        raise tokens.error
                    value = val(tokens.move())
                else:
                    value = val(left)
                    left = ""
            if tokens.error of DocoptExit:
                o.value = (if value.kind != vkNone: value else: val(true))
        result.add o


proc parse_expr(tokens: TokenStream, options: var seq[Option]): seq[Pattern] {.gcsafe.}

proc parse_pattern(source: string, options: var seq[Option]): Required =
    var tokens = token_stream(
      source.replace(re"([\[\]\(\)\|]|\.\.\.)", r" $1 "),
      new_exception(DocoptLanguageError, "")
    )
    let ret = parse_expr(tokens, options)
    if tokens.current != "":
        tokens.error.msg = "unexpected ending: '$#'".format(@tokens.join(" "))
        raise tokens.error
    required(ret)


proc parse_seq(tokens: TokenStream, options: var seq[Option]): seq[Pattern] {.gcsafe.}

proc parse_expr(tokens: TokenStream, options: var seq[Option]): seq[Pattern] =
    ## expr ::= seq ( '|' seq )* ;
    var sequ = parse_seq(tokens, options)
    if tokens.current != "|":
        return sequ
    var res = (if sequ.len > 1: @[Pattern(required(sequ))] else: sequ)
    while tokens.current == "|":
        discard tokens.move()
        sequ = parse_seq(tokens, options)
        res.add(if sequ.len > 1: @[Pattern(required(sequ))] else: sequ)
    return (if res.len > 1: @[Pattern(either(res))] else: res)



proc parse_atom(tokens: TokenStream, options: var seq[Option]): seq[Pattern] {.gcsafe.}

proc parse_seq(tokens: TokenStream, options: var seq[Option]): seq[Pattern] =
    ## seq ::= ( atom [ '...' ] )* ;
    result = @[]
    while tokens.current notin ["", "]", ")", "|"]:
        var atom = parse_atom(tokens, options)
        if tokens.current == "...":
            let oom = one_or_more(atom)
            atom = @[Pattern(oom)]
            discard tokens.move()
        result.add atom


proc parse_atom(tokens: TokenStream, options: var seq[Option]): seq[Pattern] =
    ## atom ::= '(' expr ')' | '[' expr ']' | 'options'
    ##       | long | shorts | argument | command ;
    var token = tokens.current
    if token in ["(", "["]:
        discard tokens.move()
        var matching: string
        var ret: Pattern
        case token
          of "(":
            matching = ")"
            ret = required(parse_expr(tokens, options))
          of "[":
            matching = "]"
            ret = optional(parse_expr(tokens, options))
          else:
            assert false
        if tokens.move() != matching:
            tokens.error.msg = "unmatched '$#'".format(token)
            raise tokens.error
        @[ret]
    elif token == "options":
        discard tokens.move()
        @[Pattern(any_options())]
    elif (token.starts_with "--") and token != "--":
        parse_long(tokens, options)
    elif (token.starts_with "-") and token notin ["-", "--"]:
        parse_shorts(tokens, options)
    elif (token.starts_with "<") and (token.ends_with ">") or
      is_upper(token):
        @[Pattern(argument(tokens.move()))]
    else:
        @[Pattern(command(tokens.move()))]


proc parse_argv(tokens: TokenStream, options: var seq[Option],
                options_first = false): seq[Pattern] =
    ## Parse command-line argument vector.
    ##
    ## If options_first:
    ##     argv ::= [ long | shorts ]* [ argument ]* [ '--' [ argument ]* ] ;
    ## else:
    ##     argv ::= [ long | shorts | argument ]* [ '--' [ argument ]* ] ;
    result = @[]
    while tokens.current != "":
        if tokens.current == "--":
            return result & @tokens.map_it(Pattern, argument("", val(it)))
        elif tokens.current.starts_with "--":
            result.add parse_long(tokens, options)
        elif (tokens.current.starts_with "-") and tokens.current != "-":
            result.add parse_shorts(tokens, options)
        elif options_first:
            return result & @tokens.map_it(Pattern, argument("", val(it)))
        else:
            result.add argument("", val(tokens.move()))


proc parse_defaults(doc: string): seq[Option] =
    var split = doc.split(re"\n\ *(<\S+?>|-\S+?)")
    result = @[]
    for i in 1 .. split.len div 2:
        var s = split[i*2-1] & split[i*2]
        if s.starts_with "-":
            result.add option.option_parse(s)


proc printable_usage(doc: string): string =
    var usage_split = doc.split(re"(?i)(Usage:)")
    if usage_split.len < 3:
        raise new_exception(DocoptLanguageError,
            """"usage:" (case-insensitive) not found.""")
    if usage_split.len > 3:
        raise new_exception(DocoptLanguageError,
            """More than one "usage:" (case-insensitive).""")
    usage_split.delete(0)
    usage_split.join().split(re"\n\s*\n")[0].strip()


proc formal_usage(printable_usage: string): string =
    var pu = printable_usage.split_whitespace()
    pu.delete(0)
    var pu0 = pu[0]
    pu.delete(0)
    "( " & pu.map_it(string, if it == pu0: ") | (" else: it).join(" ") & " )"


proc extras(help: bool, version: string, options: seq[Pattern], doc: string) =
    if help and options.any_it((it.name in ["-h", "--help"]) and it.value):
        echo(doc.strip())
        quit()
    elif version != "" and
      options.any_it(it.name == "--version" and it.value):
        echo(version)
        quit()


proc docopt_exc(doc: string, argv: seq[string], help: bool, version: string,
                options_first = false): Table[string, Value] =
    var doc = doc.replace("\r\l", "\l")

    var argv = (if argv.len == 0: command_line_params() else: argv)

    var docopt_exit = new_exception(DocoptExit, "")
    docopt_exit.usage = printable_usage(doc)

    var options = parse_defaults(doc)
    var pattern = parse_pattern(formal_usage(docopt_exit.usage), options)

    var argvt = parse_argv(token_stream(argv, docopt_exit), options,
                           options_first)
    var pattern_options = pattern.flat("Option").deduplicate()
    for any_options in pattern.flat("AnyOptions"):
        var doc_options = parse_defaults(doc).deduplicate()
        any_options.children = doc_options.filter_it(
          it notin pattern_options).map_it(Pattern, Pattern(it))

    extras(help, version, argvt, doc)
    pattern.fix()
    var (matched, left, collected) = pattern.match(argvt)
    if matched and left.len == 0:  # better error message if left?
        result = init_table[string, Value]()
        for a in pattern.flat():
            result[a.name] = a.value
        for a in collected:
            result[a.name] = a.value
    else:
        raise docopt_exit


proc docopt*(doc: string, argv: seq[string] = @[], help = true,
             version: string = "", options_first = false, quit = true
            ): Table[string, Value] {.gcsafe.} =
    ## Parse `argv` based on command-line interface described in `doc`.
    ##
    ## `docopt` creates your command-line interface based on its
    ## description that you pass as `doc`. Such description can contain
    ## --options, <positional-argument>, commands, which could be
    ## [optional], (required), (mutually | exclusive) or repeated...
    ##
    ## Parameters
    ## ----------
    ## doc : str
    ##     Description of your command-line interface.
    ## argv : seq[string], optional
    ##     Argument vector to be parsed. sys.argv[1:] is used if not
    ##     provided.
    ## help : bool (default: true)
    ##     Set to false to disable automatic help on -h or --help
    ##     options.
    ## version : string
    ##     If passed, the string will be printed if --version is in
    ##     `argv`.
    ## options_first : bool (default: false)
    ##     Set to true to require options precede positional arguments,
    ##     i.e. to forbid options and positional arguments intermix.
    ## quit : bool (default: true)
    ##     Set to false to let this function raise DocoptExit instead
    ##     of printing usage and quitting the application.
    ##
    ## Returns
    ## -------
    ## args : Table[string, Value]
    ##     A dictionary, where keys are names of command-line elements
    ##     such as e.g. "--verbose" and "<path>", and values are the
    ##     parsed values of those elements.
    ##
    ## Example
    ## -------
    ## import tables, docopt
    ##
    ## let doc = """
    ## Usage:
    ##     my_program tcp <host> <port> [--timeout=<seconds>]
    ##     my_program serial <port> [--baud=<n>] [--timeout=<seconds>]
    ##     my_program (-h | --help | --version)
    ##
    ## Options:
    ##     -h, --help  Show this screen and exit.
    ##     --baud=<n>  Baudrate [default: 9600]
    ## """
    ## let argv = @["tcp", "127.0.0.1", "80", "--timeout", "30"]
    ## echo docopt(doc, argv)
    ##
    ## # {serial: false, <host>: "127.0.0.1", --help: false, --timeout: "30",
    ## # --baud: "9600", --version: false, tcp: true, <port>: "80"}
    ##
    ## See also
    ## --------
    ## Full documentation: http://docopt.org/
    if not quit:
        return docopt_exc(doc, argv, help, version, options_first)
    try:
        return docopt_exc(doc, argv, help, version, options_first)
    except DocoptExit:
        stderr.write_line((ref DocoptExit)(get_current_exception()).usage)
        quit()
