package dbixcsl_dumper_tests;

use strict;
use Test::More;
use File::Path;
use IPC::Open3;
use DBIx::Class::Schema::Loader::Utils 'dumper_squashed';
use DBIx::Class::Schema::Loader ();

use dbixcsl_test_dir qw/$tdir/;

my $DUMP_PATH = "$tdir/dump";
sub cleanup {
    rmtree($DUMP_PATH, 1, 1);
}

sub append_to_class {
    my ($self, $class, $string) = @_;
    $class =~ s{::}{/}g;
    $class = $DUMP_PATH . '/' . $class . '.pm';
    open(my $appendfh, '>>', $class) or die "Failed to open '$class' for append: $!";
    print $appendfh $string;
    close($appendfh);
}

sub dump_test {
    my ($self, %tdata) = @_;


    $tdata{options}{dump_directory} = $DUMP_PATH;
    $tdata{options}{use_namespaces} ||= 0;

    for my $dumper (\&_dump_directly, \&_dump_dbicdump) {
        _test_dumps(\%tdata, $dumper->(%tdata));
    }
}


sub _dump_directly {
    my %tdata = @_;

    my $schema_class = $tdata{classname};

    no strict 'refs';
    @{$schema_class . '::ISA'} = ('DBIx::Class::Schema::Loader');
    $schema_class->loader_options(%{$tdata{options}});

    my @warns;
    eval {
        local $SIG{__WARN__} = sub { push(@warns, @_) };
        $schema_class->connect(_get_dsn(\%tdata));
    };
    my $err = $@;

    $schema_class->storage->disconnect if !$err && $schema_class->storage;
    undef *{$schema_class};

    _check_error($err, $tdata{error});

    return @warns;
}

sub _dump_dbicdump {
    my %tdata = @_;

    # use $^X so we execute ./script/dbicdump with the same perl binary that the tests were executed with
    my @cmd = ($^X, qw(script/dbicdump));

    while (my ($opt, $val) = each(%{ $tdata{options} })) {
        $val = dumper_squashed $val if ref $val;
        push @cmd, '-o', "$opt=$val";
    }

    push @cmd, $tdata{classname}, _get_dsn(\%tdata);

    # make sure our current @INC gets used by dbicdump
    use Config;
    local $ENV{PERL5LIB} = join $Config{path_sep}, @INC, ($ENV{PERL5LIB} || '');

    my ($in, $out, $err);
    my $pid = open3($in, $out, $err, @cmd);

    my @out = <$out>;
    waitpid($pid, 0);

    if ($? >> 8 != 0) {
        my $error = pop @out;
        _check_error($error, $tdata{error});
    }

    return @out;
}

sub _get_dsn {
    my $opts = shift;

    my $test_db_class = $opts->{test_db_class} || 'make_dbictest_db';

    eval "require $test_db_class;";
    die $@ if $@;

    my $dsn = do {
        no strict 'refs';
        ${$test_db_class . '::dsn'};
    };

    return $dsn;
}

sub _check_error {
    my ($got, $expected) = @_;

    return unless $got;

    if (not $expected) {
        fail "Unexpected error in " . ((caller(1))[3]) . ": $got";
        return;
    }

    if (ref $expected eq 'Regexp') {
        like $got, $expected, 'error matches expected pattern';
        return;
    }

    is $got, $expected, 'error matches';
}


sub _test_dumps {
    my ($tdata, @warns) = @_;

    my %tdata = %{$tdata};

    my $schema_class = $tdata{classname};
    my $check_warns = $tdata{warnings};
    is(@warns, @$check_warns, "$schema_class warning count");

    for(my $i = 0; $i <= $#$check_warns; $i++) {
        like($warns[$i], $check_warns->[$i], "$schema_class warning $i");
    }

    my $file_regexes = $tdata{regexes};
    my $file_neg_regexes = $tdata{neg_regexes} || {};
    my $schema_regexes = delete $file_regexes->{schema};

    my $schema_path = $DUMP_PATH . '/' . $schema_class;
    $schema_path =~ s{::}{/}g;

    _dump_file_like($schema_path . '.pm', @$schema_regexes) if $schema_regexes;

    foreach my $src (keys %$file_regexes) {
        my $src_file = $schema_path . '/' . $src . '.pm';
        _dump_file_like($src_file, @{$file_regexes->{$src}});
    }
    foreach my $src (keys %$file_neg_regexes) {
        my $src_file = $schema_path . '/' . $src . '.pm';
        _dump_file_not_like($src_file, @{$file_neg_regexes->{$src}});
    }
}

sub _dump_file_like {
    my $path = shift;
    open(my $dumpfh, '<', $path) or die "Failed to open '$path': $!";
    my $contents = do { local $/; <$dumpfh>; };
    close($dumpfh);
    like($contents, $_, "$path matches $_") for @_;
}

sub _dump_file_not_like {
    my $path = shift;
    open(my $dumpfh, '<', $path) or die "Failed to open '$path': $!";
    my $contents = do { local $/; <$dumpfh>; };
    close($dumpfh);
    unlike($contents, $_, "$path does not match $_") for @_;
}

END {
    __PACKAGE__->cleanup unless $ENV{SCHEMA_LOADER_TESTS_NOCLEANUP}
}