package ETL::Yertl::Command::ysql;
our $VERSION = '0.045';
# ABSTRACT: Read and write documents with a SQL database

use ETL::Yertl;
use ETL::Yertl::Util qw( load_module docs_from_string );
use Getopt::Long qw( GetOptionsFromArray :config pass_through );
use File::HomeDir;
use Path::Tiny qw( tempfile );
use SQL::Abstract;
use IO::Async::Loop;
use ETL::Yertl::Format;
use ETL::Yertl::FormatStream;
use Scalar::Util qw( looks_like_number );

sub main {
    my $class = shift;

    eval { require DBI; };
    if ( $@ ) {
        die "Can't load ysql: Can't load DBI. Make sure the DBI module is installed.\n";
    }

    my %opt;
    if ( ref $_[-1] eq 'HASH' ) {
        %opt = %{ pop @_ };
    }

    my @args = @_;
    GetOptionsFromArray( \@args, \%opt,
        'config',
        'drivers',
        'driver|t=s',
        'database|db=s',
        'host|h=s',
        'port|p=s',
        'user|u=s',
        'password|pass=s',
        'save=s',
        'edit|e=s',
        'select=s',
        'count=s',
        'insert=s',
        'delete=s',
        'where=s',
        'order|order-by|sort=s',
    );
    #; use Data::Dumper;
    #; say Dumper \@args;
    #; say Dumper \%opt;

    my $out_fmt = ETL::Yertl::Format->get_default;

    if ( $opt{config} ) {
        my $db_key = shift @args;

        if ( !$db_key ) {
            my $out_fmt = ETL::Yertl::Format->get( 'yaml' );
            print $out_fmt->format( config() );
            return 0;
        }

        # Get the existing config first
        my $db_conf = db_config( $db_key );

        if ( !@args && !grep { defined } @opt{qw( dsn driver database host port user password )} ) {
            die "Database key '$db_key' does not exist" unless keys %$db_conf;
            my $out_fmt = ETL::Yertl::Format->get( 'yaml' );
            print $out_fmt->format( $db_conf );
            return 0;
        }

        #; use Data::Dumper;
        #; say "Got from options: " . Dumper $db_conf;
        #; say "Left in \@args: " . Dumper \@args;

        for my $key ( qw{ driver database host port user password } ) {
            next if !$opt{ $key };
            $db_conf->{ $key } = $opt{ $key };
        }

        # Set via DSN
        if ( my $dsn = $opt{dsn} || shift( @args ) ) {
            delete $db_conf->{ $_ } for qw( driver database host port );
            my ( undef, $driver, undef, undef, $driver_dsn ) = DBI->parse_dsn( $dsn );
            $db_conf->{ driver } = $driver;

            # The driver_dsn part is up to the driver, but we can make some guesses
            if ( $driver_dsn !~ /[=:;@]/ ) {
                $db_conf->{ database } = $driver_dsn;
            }
            elsif ( $driver_dsn =~ /^(\w+)\@([\w.]+)(?:\:(\d+))?$/ ) {
                $db_conf->{ database } = $1;
                $db_conf->{ host } = $2;
                $db_conf->{ port } = $3;
            }
            elsif ( my @parts = split /\;/, $driver_dsn ) {
                for my $part ( @parts ) {
                    my ( $part_key, $part_value ) = split /=/, $part;
                    if ( $part_key eq 'dbname' ) {
                        $part_key = 'database';
                    }
                    $db_conf->{ $part_key } = $part_value;
                }
            }
            else {
                die "Unknown driver DSN: $driver_dsn";
            }
        }

        # Check if the driver is installed
        my $driver = $db_conf->{driver};
        if ( !grep { /^$driver$/ } DBI->available_drivers ) {
            my @possible = grep { /^$driver$/i } DBI->available_drivers;
            my $suggest = @possible ? " Did you mean: $possible[0]" : '';
            warn "Driver '$driver' does not exist." . $suggest . "\n";
        }

        # Write back the config
        db_config( $db_key => $db_conf );

    }
    elsif ( $opt{drivers} ) {
        my $ignore = join "|", qw( ExampleP Sponge File );
        say join "\n", grep { !/^(?:$ignore)$/ } DBI->available_drivers;

    }
    else {
        if ( $opt{ edit } ) {
            my $db_key = shift @args;
            my $db_conf = db_config( $db_key );
            my $query = $db_conf->{query}{ $opt{edit} };
            my $tmp = tempfile;
            $tmp->spew( $query );
            system $ENV{EDITOR}, "$tmp";
            $db_conf->{query}{ $opt{edit} } = $tmp->slurp;
            db_config( $db_key => $db_conf );
            return 0;
        }

        if ( $opt{ save } ) {
            my $db_key = shift @args;
            my $db_conf = db_config( $db_key );
            $db_conf->{query}{ $opt{save} } = shift @args;
            db_config( $db_key => $db_conf );
            return 0;
        }

        my $db_key = !$opt{dsn} ? shift @args : undef;
        if ( !$db_key && !$opt{dsn} ) {
            die "Must specify a database!\n";
        }

        my @dbi_args = $opt{dsn} ? ( $opt{dsn}, undef, undef ) : dbi_args( $db_key );
        if ( !@dbi_args ) {
            die "Unknown database '$db_key'\n";
        }

        my $dbh = DBI->connect( @dbi_args, { PrintError => 0 } );
        if ( !$dbh ) {
            no warnings 'once';
            die sprintf qq{Could not connect to database "\%s"\%s: \%s\n},
                $dbi_args[0],
                $dbi_args[1] ? qq{ (user: "$dbi_args[1]")} : '',
                $DBI::errstr;
        }

        my $sql = SQL::Abstract->new;

        # Insert helper requires special handling, as the query may change
        # with every document inserted.
        if ( $opt{insert} ) {
            if ( !-t *STDIN && !-z *STDIN ) {
                my $query;
                my @bind_args;
                my $sth;

                my $loop = IO::Async::Loop->new;
                my $in_stream = ETL::Yertl::FormatStream->new_for_stdin(
                    on_doc => sub {
                        my ( $self, $doc, $eof ) = @_;
                        return unless $doc;

                        if ( grep { ref } values %$doc ) {
                            die q{Can't insert complex data structures using '--insert'. Please use SQL with '$' placeholders instead}."\n";
                        }

                        my ( $new_query, @bind_args ) = $sql->insert( $opt{insert}, $doc );
                        if ( !$query || $new_query ne $query ) {
                            $query = $new_query;
                            $sth = $dbh->prepare( $query )
                                or die _query_error( "prepare", $dbh, $query, \@bind_args );
                        }

                        $sth->execute( @bind_args )
                            or die _query_error( "execute", $dbh, $query, \@bind_args );
                        while ( my $doc = $sth->fetchrow_hashref ) {
                            print $out_fmt->format( $doc );
                        }
                    },
                    on_read_eof => sub { $loop->stop },
                );
                $loop->add( $in_stream );
                $loop->run;

            }
            else {
                my ( $query, @bind_args ) = $sql->insert( $opt{insert}, \@args );
                my $sth = $dbh->prepare( $query )
                    or _query_error( "prepare", $dbh, $query, \@bind_args );

                $sth->execute( @bind_args )
                    or _query_error( "execute", $dbh, $query, \@bind_args );
                while ( my $doc = $sth->fetchrow_hashref ) {
                    print $out_fmt->format( $doc );
                }
            }
            return 0;
        }

        # Other queries that do not require special handling
        my $query;
        if ( $opt{select} ) {
            $query = $sql->select( $opt{select}, '*', $opt{where}, $opt{order} );
        }
        elsif ( $opt{count} ) {
            $query = $sql->select( $opt{count}, 'COUNT(*) AS value', $opt{where} );
        }
        elsif ( $opt{delete} ) {
            $query = $sql->delete( $opt{delete}, $opt{where} );
        }
        else {
            $query = shift @args;

            # Check for saved query
            if ( $db_key ) {
                my $db_conf = db_config( $db_key );
                if ( $db_conf->{query}{ $query } ) {
                    $query = $db_conf->{query}{ $query };
                }
            }
        }

        # Resolve interpolations with placeholders
        my @fields = $query =~ m/\$(\.[.\w]+)/g;
        $query =~ s/\$\.[\w.]+/?/g;

        my $sth = $dbh->prepare( $query )
            or _query_error( "prepare", $dbh, $query, [] );

        if ( !-t *STDIN && !-z *STDIN ) {
            my $loop = IO::Async::Loop->new;
            my $in_stream = ETL::Yertl::FormatStream->new_for_stdin(
                on_doc => sub {
                    my ( $self, $doc, $eof ) = @_;
                    return unless $doc;

                    my @bind_args = map { select_doc( $_, $doc ) } @fields;
                    $sth->execute( @bind_args )
                        or _query_error( "execute", $dbh, $query, \@bind_args );
                    while ( my $doc = $sth->fetchrow_hashref ) {
                        print $out_fmt->write( $doc );
                    }
                },
                on_read_eof => sub { $loop->stop },
            );

            $loop->add( $in_stream );
            $loop->run;
        }
        else {
            $sth->execute( @args )
                or _query_error( "execute", $dbh, $query, \@args );
            while ( my $doc = $sth->fetchrow_hashref ) {
                print $out_fmt->format( $doc );
            }
        }

        return 0;
    }
}

sub _query_error {
    my ( $method, $dbh, $query, $bind_args ) = @_;
    my $error = qq{SQL error in %s: %s\n  Query: %s\n};
    my @fields = ( $method, $dbh->errstr, $query );
    if ( $method eq 'execute' ) {
        $error .= "  Binds: %s\n";
        if ( @$bind_args ) {
            push @fields,
                join ", ",
                map { looks_like_number $_ ? $_ : qq{"$_"} }
                @$bind_args
                ;
        }
        else {
            push @fields, '<none>';
        }
    }
    die sprintf $error, @fields;
}

sub config {
    my $conf_file = path( File::HomeDir->my_home, '.yertl', 'ysql.yml' );
    my $config;
    if ( $conf_file->exists ) {
        ( $config ) = docs_from_string( yaml => $conf_file->slurp );
    }
    return $config || {};
}

sub db_config {
    my ( $db_key, $config ) = @_;
    if ( $config ) {
        my $conf_file = path( File::HomeDir->my_home, '.yertl', 'ysql.yml' );
        if ( !$conf_file->exists ) {
            $conf_file->touchpath;
        }
        my $all_config = config();
        $all_config->{ $db_key } = $config;
        my $yaml = load_module( format => 'yaml' )->new;
        $conf_file->spew( $yaml->format( $all_config ) );
        return;
    }
    return config()->{ $db_key } || {};
}

sub select_doc {
    my ( $select, $doc ) = @_;
    $select =~ s/^[.]//; # select must start with .
    my @parts = split /[.]/, $select;
    for my $part ( @parts ) {
        $doc = $doc->{ $part };
    }
    return $doc;
}

sub dbi_args {
    my ( $db_name ) = @_;
    my $conf_file = path( File::HomeDir->my_home, '.yertl', 'ysql.yml' );
    if ( $conf_file->exists ) {
        my ( $config ) = docs_from_string( yaml => $conf_file->slurp );
        my $db_config = $config->{ $db_name };

        my $driver_dsn =
            join ";",
            map { join "=", $_, $db_config->{ $_ } }
            grep { $db_config->{ $_ } }
            qw( database host port )
            ;

        return (
            sprintf( 'dbi:%s:%s', $db_config->{driver}, $driver_dsn ),
            $db_config->{user},
            $db_config->{password},
        );
    }
}

1;
__END__

