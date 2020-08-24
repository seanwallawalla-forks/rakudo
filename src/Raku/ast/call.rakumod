# An argument list.
class RakuAST::ArgList is RakuAST::Node {
    has List $!args;

    method new(*@args) {
        my $obj := nqp::create(self);
        nqp::bindattr($obj, RakuAST::ArgList, '$!args', @args);
        $obj
    }

    method from-comma-list(RakuAST::ApplyListInfix $comma-apply) {
        my $obj := nqp::create(self);
        nqp::bindattr($obj, RakuAST::ArgList, '$!args',
            self.IMPL-UNWRAP-LIST($comma-apply.operands));
        $obj
    }

    method args() {
        self.IMPL-WRAP-LIST($!args)
    }

    method visit-children(Code $visitor) {
        my @args := $!args;
        for @args {
            $visitor($_);
        }
    }

    method IMPL-ADD-QAST-ARGS(RakuAST::IMPL::QASTContext $context, QAST::Op $call) {
        # We need to remove duplicate named args, so make a first pass through to
        # collect those.
        my %named-counts;
        for $!args -> $arg {
            if nqp::istype($arg, RakuAST::NamedArg) {
                %named-counts{$arg.named-arg-name}++;
            }
        }

        # Now emit code to compile and pass each argument.
        for $!args -> $arg {
            if nqp::istype($arg, RakuAST::ApplyPrefix) &&
                    nqp::istype($arg.prefix, RakuAST::Prefix) &&
                    $arg.prefix.operator eq '|' {
                # Flattening argument; evaluate it once and pass the array and hash
                # flattening parts.
                my $temp := QAST::Node.unique('flattening_');
                $call.push(QAST::Op.new(
                    :op('callmethod'), :name('FLATTENABLE_LIST'),
                    QAST::Op.new(
                        :op('bind'),
                        QAST::Var.new( :name($temp), :scope('local'), :decl('var') ),
                        $arg.operand.IMPL-TO-QAST($context)
                    ),
                    :flat(1)
                ));
                $call.push(QAST::Op.new(
                    :op('callmethod'), :name('FLATTENABLE_HASH'),
                    QAST::Var.new( :name($temp), :scope('local') ),
                    :flat(1), :named(1)
                ));
            }
            elsif nqp::istype($arg, RakuAST::NamedArg) {
                my $name := $arg.named-arg-name;
                if %named-counts{$name} == 1 {
                    # It's the final appearance of this name, so emit it as the
                    # named argument.
                    my $val-ast := $arg.named-arg-value.IMPL-TO-QAST($context);
                    $val-ast.named($name);
                    $call.push($val-ast);
                }
                else {
                    # It's a discarded value. If it has side-effects, then we
                    # must evaluate those.
                    my $value := $arg.named-arg-value;
                    unless $value.pure {
                        $call.push(QAST::Stmts.new(
                            :flat,
                            $value.IMPL-TO-QAST($context),
                            QAST::Op.new( :op('list') ) # flattens to nothing
                        ));
                    }
                    %named-counts{$name}--;
                }
            }
            else {
                # Positional argument.
                $call.push($arg.IMPL-TO-QAST($context))
            }
        }
    }
}

# Base role for all kinds of calls (named sub calls, calling some term, and
# method calls).
class RakuAST::Call is RakuAST::Sinkable {
    has RakuAST::ArgList $.args;

    method IMPL-APPLY-SINK(Mu $qast) {
        self.sunk
            ?? QAST::Op.new( :op('p6sink'), $qast )
            !! $qast
    }
}

# A call to a named sub.
class RakuAST::Call::Name is RakuAST::Term is RakuAST::Call is RakuAST::Lookup {
    has RakuAST::Name $.name;

    method new(RakuAST::Name :$name!, RakuAST::ArgList :$args) {
        my $obj := nqp::create(self);
        nqp::bindattr($obj, RakuAST::Call::Name, '$!name', $name);
        nqp::bindattr($obj, RakuAST::Call, '$!args', $args // RakuAST::ArgList.new);
        $obj
    }

    method visit-children(Code $visitor) {
        $visitor($!name);
        $visitor(self.args);
    }

    method needs-resolution() { $!name.is-identifier }

    method resolve-with(RakuAST::Resolver $resolver) {
        my $resolved := $resolver.resolve-name($!name, :sigil('&'));
        if $resolved {
            self.set-resolution($resolved);
        }
        Nil
    }

    method IMPL-TO-QAST(RakuAST::IMPL::QASTContext $context) {
        my $call := QAST::Op.new( :op('call') );
        if $!name.is-identifier {
            $call.name(self.resolution.lexical-name);
        }
        else {
            nqp::die('compiling complex call names NYI')
        }
        self.args.IMPL-ADD-QAST-ARGS($context, $call);
        self.IMPL-APPLY-SINK($call)
    }
}

# A call to any term (the postfix () operator).
class RakuAST::Call::Term is RakuAST::Call is RakuAST::Postfixish {
    method new(RakuAST::ArgList :$args) {
        my $obj := nqp::create(self);
        nqp::bindattr($obj, RakuAST::Call, '$!args', $args // RakuAST::ArgList.new);
        $obj
    }

    method visit-children(Code $visitor) {
        $visitor(self.args);
    }

    method IMPL-POSTFIX-QAST(RakuAST::IMPL::QASTContext $context, Mu $callee-qast) {
        my $call := QAST::Op.new( :op('call'), $callee-qast );
        self.args.IMPL-ADD-QAST-ARGS($context, $call);
        self.IMPL-APPLY-SINK($call)
    }
}

# A call to a method.
class RakuAST::Call::Method is RakuAST::Call is RakuAST::Postfixish {
    has RakuAST::Name $.name;

    method new(RakuAST::Name :$name!, RakuAST::ArgList :$args) {
        my $obj := nqp::create(self);
        nqp::bindattr($obj, RakuAST::Call::Method, '$!name', $name);
        nqp::bindattr($obj, RakuAST::Call, '$!args', $args // RakuAST::ArgList.new);
        $obj
    }

    method visit-children(Code $visitor) {
        $visitor($!name);
        $visitor(self.args);
    }

    method IMPL-POSTFIX-QAST(RakuAST::IMPL::QASTContext $context, Mu $invocant-qast) {
        if $!name.is-identifier {
            my $name := self.IMPL-UNWRAP-LIST($!name.parts)[0].name;
            my $call := QAST::Op.new( :op('callmethod'), :$name, $invocant-qast );
            self.args.IMPL-ADD-QAST-ARGS($context, $call);
            self.IMPL-APPLY-SINK($call)
        }
        else {
            nqp::die('Qualified method calls NYI');
        }
    }
}
