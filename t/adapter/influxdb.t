
=head1 DESCRIPTION

This test ensures that the InfluxDB adapter (L<ETL::Yertl::Adapter::influxdb>)
is able to read/write time series data

=head1 SEE ALSO

L<yts>

=cut

use ETL::Yertl 'Test';
use IO::Async::Loop;
use IO::Async::Test;
use Mock::MonkeyPatch;
use Future;
use HTTP::Response;
use JSON::PP qw( encode_json );
use ETL::Yertl::Adapter::influxdb;

my $loop = IO::Async::Loop->new();
testing_loop( $loop );

subtest 'constructor spec' => sub {
    subtest 'success' => sub {
        my $db = ETL::Yertl::Adapter::influxdb->new( 'influxdb://localhost:8086' );
        is $db->{host}, 'localhost', 'host is correct';
        is $db->{port}, 8086, 'port is correct';
    };

    subtest 'port defaults to 8086' => sub {
        my $db = ETL::Yertl::Adapter::influxdb->new( 'influxdb://localhost' );
        is $db->{host}, 'localhost', 'host is correct';
        is $db->{port}, 8086, 'port is correct';
    };

    subtest 'host is required' => sub {
        dies_ok { ETL::Yertl::Adapter::influxdb->new( 'influxdb://:8086' ) };
    };

};

subtest 'read ts' => sub {
    my $db = ETL::Yertl::Adapter::influxdb->new(
        _loop => $loop,
        host => 'localhost',
    );

    my $content = encode_json(
        {
            results => [
                {
                    statement_id => 0,
                    series => [
                        {
                            name => "cpu_load_1m",
                            columns => [qw( time value )],
                            values => [
                                [
                                    "2017-01-01T00:00:00",
                                    1.23
                                ],
                                [
                                    "2017-01-01T00:00:10",
                                    1.26
                                ]
                            ]
                        }
                    ]
                }
            ]
        },
    );
    my $mock = Mock::MonkeyPatch->patch(
        'Net::Async::HTTP::GET' => sub {
            return Future->done(
                HTTP::Response->new(
                    200 => 'OK',
                    [
                        'Content-Length' => length $content,
                        'Content-Type' => 'text/plain',
                    ],
                    $content,
                ),
            );
        },
    );

    my @points = $db->read_ts( { metric => 'mydb.cpu_load_1m.value' } );
    cmp_deeply \@points, [
        {
            timestamp => '2017-01-01T00:00:00',
            metric => 'mydb.cpu_load_1m',
            value => 1.23,
        },
        {
            timestamp => '2017-01-01T00:00:10',
            metric => 'mydb.cpu_load_1m',
            value => 1.26,
        },
    ];

    ok $mock->called, 'mock GET called';
    my $args = $mock->method_arguments;
    my $url = URI->new( $args->[0] );
    is $url->host_port, 'localhost:8086', 'host/port is correct';
    cmp_deeply { $url->query_form }, {
        db => 'mydb',
        q => 'SELECT "value" FROM "cpu_load_1m"',
    }, 'query params correct';
};

subtest 'write ts' => sub {
    my $db = ETL::Yertl::Adapter::influxdb->new(
        _loop => $loop,
        host => 'localhost',
    );

    my $mock = Mock::MonkeyPatch->patch(
        'Net::Async::HTTP::POST' => sub {
            return Future->done(
                HTTP::Response->new(
                    204 => 'No Content',
                    [
                        'Content-Length' => 0,
                    ],
                ),
            );
        },
    );

    my @points = (
        {
            timestamp => 1483228800,
            metric => 'mydb.cpu_load.5m',
            value => 1.23,
        },
        {
            timestamp => '2017-01-01T00:05:00',
            metric => 'mydb.cpu_load.5m',
            value => 1.25,
        },
        {
            metric => 'mydb.cpu_load.1m',
            value => 1.26,
        },
    );

    my $time = time;
    no warnings 'once';
    local *CORE::GLOBAL::time = sub { $time };
    use warnings;
    $db->write_ts( @points );

    ok $mock->called, 'mock POST called';
    my $args = $mock->method_arguments;
    is $args->[0], 'http://localhost:8086/write?db=mydb', 'POST URL correct';
    my @lines = (
        "cpu_load 5m=1.23 1483228800000000000",
        "cpu_load 5m=1.25 1483229100000000000",
        "cpu_load 1m=1.26 " . ( $time * 10**9 ),
    );
    is $args->[1], join( "\n", @lines ), 'influxdb line protocol points correct';
    cmp_deeply { @{ $args }[ 2..$#$args ] },
        { content_type => 'text/plain' },
        'additional options are correct';
};

done_testing;
