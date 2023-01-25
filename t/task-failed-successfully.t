#!perl

use strict;
use warnings;

use Test::More qw(no_plan);
use Test::Warnings;
use Test::Fatal;
use Config;
require IO::Pty;

BEGIN {
    use_ok('Test::NoTty');
}

is(eval "sub foo { without_tty(42); };", undef, "without_tty prototype enforced");
like($@, qr/\AType of arg 1 to Test::NoTty::without_tty must be block or sub /,
     "must be a block or sub");

# A lexical will be a syntax error if I typo it. A fixed string will slip past.
my $dev_tty = '/dev/tty';

# Someone, somewhere, is going to try to cheat...
BAIL_OUT("$dev_tty is now missing - Makefile.PL should have checked for this")
    unless -e $dev_tty;

my $pty;
if (open my $tty, '+<', $dev_tty) {
    # That would be *bad*:
    close $tty
        or die "Failed to *close* $dev_tty: $!";
} else {
    # We don't *have* a controling terminal, so we need to create one just so
    # that we can test getting rid of it :-)
    note("Using IO::Pty to create a controlling terminal...");
    $pty = IO::Pty->new;
    # This is still the term Open Group are using for this end:
    $pty->make_slave_controlling_terminal();

    if (open my $tty, '+<', $dev_tty) {
        note("Our pseudo-terminal is now our controlling terminal \\o/");
        # That would be *bad*:
        close $tty
            or die "Failed to *close* our pseudo-tty: $!";
    } else {
        die "Failed to attach our pseudo-tty as $dev_tty";
    }
    # We now return you to your regularly scheduled programming...
}

my $have = without_tty {
    return 42
        if open my $fh, '+<', $dev_tty;
    # We should get here:
    return 6 * 9;
};
is($have, 54, "Failed to open $dev_tty in the block called by without_tty");

{
    my $pid = $$;
    # "Pick a card"
    my @array = keys %ENV;
    my $index = rand @array;
    my $pick = $array[$index];

    # You can use this sort of construction to run tests within the your block:
    my $Test = Test::Builder->new;
    my $curr_test = $Test->current_test;
    my $count = without_tty(sub {
        my ($a) = @_;
        isnt($$, $pid, "We're actually running in a different process");
        # We can pass *in* arguments, including structures and objects
        # And we inherit our lexical state, just as expected
        is($a->[$index], $pick, "Random array of element found");

        # Two tests ran in the child that our parent doesn't know about:
        return 2;
    }, \@array);
    $Test->current_test($curr_test + $count);
}

sub die_string {
    die "Exceptions are propagated";
    return 1;
}

like(exception(sub {
    without_tty(\&die_string);
    fail("The code above should have died, hence this line should not execute");
}), qr/\AExceptions are propagated at /);

sub die_object {
    die bless ["The marvel is not that the bear dances well, but that the bear dances at all."],
        "Some::Class";
    return 7;
}

# Object exceptions can't work:
like(exception(sub {
    without_tty(\&die_object);
    fail("The code above should have died, hence this line should not execute");
}), qr/\ASome::Class=ARRAY\(0x/);

is(exception(sub {
    is(without_tty(sub {
        my $have = eval {
            die "This should be trapped";
            1;
        };
        return 1
            if defined $have;
        return $@ =~ qr/\AThis should be trapped at/ ? 3 : 2;
    }), 3, 'eval should "work" in the tested code');
}), undef, 'eval in the tested code should not leak the exception');


my $sig = 'INT';
my $sig_num;
my $i = 0;
for my $name (split ' ', $Config{sig_name}) {
    if ($name eq $sig) {
        $sig_num = $i;
        last;
    }
    ++$i;
}

SKIP: {
    skip("Could not find signal number for $sig", 1)
        unless $sig_num;

    # Signals are reported:
    like(exception(sub {
        without_tty(sub {
            kill $sig, $$;
            return 9;
        });
        fail("The code above should have died, hence this line should not execute");
    }), qr/\ACode called by without_tty\(\) died with signal $sig_num /);
}

# Testing the code for "signals are propagated (best effort)" is rather hard to
# implement reliably. without_tty() tries hard to run the block passed to it
# synchronously - ie ensure that that code runs to completion before returning.
# Meaning that we need some way to trigger a signal during its call waitpid
# which in turn kills the parent process, to trigger the module code that
# propagates that signal to the child, and then what? The child should exit,
# but the parent code isn't robust enough to retry waitpid to get the real
# status...
# The point of the *parent* signal handling was to make control-C interrupt an
# interactive test (rather than the forked child detaching and continuing
# despite the parent exiting and the shell prompt appearing)
# Not to do anything more reliable than that.

if ($pty) {
    local $SIG{HUP} = sub {
        note("Got a HUP when closing my controlling terminal - this is expected");
    };
    my $got = $pty->close;
}

done_testing;
