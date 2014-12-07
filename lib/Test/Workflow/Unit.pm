package Test::Workflow::Unit;
use strict;
use warnings;

use Scalar::Util qw/blessed/;
use Test::Stream::Carp qw/confess/;
use Test::Stream::Util qw/try/;
use Test::Stream::Subtest qw/subtest/;

use Test::Stream::ArrayBase(
    accessors => [qw/stateful comp core before after affix scheduler is_test/],
);

sub init {
    my $self = shift;

    confess "core must be specified"
        unless $self->[CORE];

    confess "scheduler must be specified"
        unless $self->[SCHEDULER];

    $self->[BEFORE] ||= [];
    $self->[AFTER]  ||= [];
}

sub multiply {
    my $self = shift;
    my ($unit) = @_;

    my $class = blessed($self);

    my $clone = $class->new(map {
        my $ref = ref($_) || ""; # Do not use reftype, we want class if it is blessed.
        # If it is an unblessed array make a shallow copy, otherwise return as-is
        $ref eq 'ARRAY' ? [@{$_}] : $_;
    } @$self);

    $clone->[IS_TEST] = $unit->[IS_TEST] . " x " . $clone->[IS_TEST]
        if $clone->[IS_TEST] && $unit->[IS_TEST];

    # -1 is before only, 0 is both, 1 is after only
    unshift @{$clone->[BEFORE]} => [$unit, $unit->[AFFIX]] unless $unit->[AFFIX] > 0;
    unshift @{$clone->[AFTER]}  => $unit                   unless $unit->[AFFIX] < 0;

    return $clone;
}

sub alter {
    my $self = shift;
    my ($modifier, $affix) = @_;

    # -1 is before only, 0 is both, 1 is after only
    push @{$self->[BEFORE]} => [$modifier, $affix] unless $affix > 0;
    push @{$self->[AFTER]}  => $modifier           unless $affix < 0;
}

sub run {
    my $self = shift;
    my @args = @_;

    my $inner = undef;
    my $affix = $self->affix;
    if (defined($affix) && $affix == 0) {
        $inner = shift @args;
    }

    my @before = @{$self->[BEFORE]};
    my @after  = @{$self->[AFTER]};

    $self->[SCHEDULER]->push_state if $self->[STATEFUL];

    my ($ok, $err) = try {
        my $code = sub {
            $self->_run(
                args   => \@args,
                before => \@before,
                after  => \@after,
                end_at => undef,
                inner  => $inner,
            );
        };

        if ($self->is_test) {
            subtest($self->is_test, $code);
        }
        else {
            $code->();
        }
    };

    $self->[SCHEDULER]->pop_state if $self->[STATEFUL];

    die $err unless $ok;
}

sub _run {
    my $self = shift;
    my %params = @_;

    my $before  = $params{before};
    my $after   = $params{after};
    my $end_at  = $params{end_at};
    my $args    = $params{args};
    my $inner   = $params{inner};

    my ($bok, $berr) = try {
        while (my $it = shift @$before) {
            my ($mod, $affix) = @$it;

            if (defined($affix) && $affix == 0) {
                $mod->run(sub {
                    $self->_run(
                        args   => $args,
                        before => $before,
                        after  => $after,
                        end_at => $mod,
                        inner  => undef,
                    );
                }, @$args);
                next;
            }
            $mod->run(@$args);
        }
    };

    my ($cok, $cerr) = (1, undef);
    if ($bok) {
        my ($cok, $cerr) = try {
            if ($self->[CORE]->isa(__PACKAGE__)) {
                $self->[SCHEDULER]->run_unit($self->[CORE], 1, $inner ? ($inner) : ());
            }
            else {
                $self->[CORE]->run($inner ? ($inner, @$args) : @$args);
            }
        };
    }

    my ($aok, $aerr) = (1, undef);
    if ($bok || $self->[STATEFUL]) { # Do not run if the buildup failed, unless state needs to be unwound.
        ($aok, $aerr) = try {
            while (my $it = shift @$after) {
                $it->run(@$args);

                next unless $end_at;
                confess "Invalid wrap stack! (Internal error?)"
                    unless @$after;

                last if $end_at == $after->[0];
            }
        }
    }

    # Order is intentional, we want to throw the first error we got, and warn
    # about the others
    my @exceptions = grep { $_ } $aerr, $cerr, $berr;
    return unless @exceptions;

    while (my $e = shift @exceptions) {
        die $e unless @exceptions;
        chomp($e);
        warn "Secondary Exception: $e\n";
    }
}

1;
