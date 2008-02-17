#!/usr/bin/env perl

use strict;
use warnings;

use Test::More tests => 10;

diag( "Testing POE::Component::WWW::PAUSE::RecentUpoads::Tail $POE::Component::WWW::PAUSE::RecentUpoads::Tail::VERSION, Perl $], $^X" );

BEGIN {
    use_ok('Carp');
    use_ok('POE');
    use_ok('Storable');
    use_ok('POE::Wheel::Run');
    use_ok('POE::Filter::Line');
    use_ok('POE::Filter::Reference');
    use_ok('POE::Component::WWW::PAUSE::RecentUploads');
    use_ok('POE::Component::WWW::PAUSE::RecentUploads::Tail');
};

use POE qw(Component::WWW::PAUSE::RecentUploads::Tail);

my $poco = POE::Component::WWW::PAUSE::RecentUploads::Tail->spawn(
    login => 'FAKE',
    pass  => 'FAKE',
    store => 'data.file',
    debug => 1,
);

isa_ok( $poco, 'POE::Component::WWW::PAUSE::RecentUploads::Tail' );
can_ok( $poco, qw(spawn shutdown fetch session_id stop_interval) );

POE::Session->create(
    package_states => [
        main => [ qw( _start ) ],
    ],
);

$poe_kernel->run;

sub _start {
    $poco->shutdown;
}

