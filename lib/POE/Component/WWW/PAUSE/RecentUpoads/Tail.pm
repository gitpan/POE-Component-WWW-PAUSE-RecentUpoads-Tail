package POE::Component::WWW::PAUSE::RecentUpoads::Tail;

use warnings;
use strict;

our $VERSION = '0.04';

use Carp;
use Storable;
use POE qw(Component::WWW::PAUSE::RecentUploads);

sub spawn {
    my $class = shift;
    
    croak "Must have even number of arguments to $class"
        if @_ & 1;

    my %params = @_;
    $params{ lc $_ } = delete $params{ $_ } for keys %params;

    delete $params{options}
        unless ref $params{options} eq 'HASH';

    for ( qw(login pass) ) {
        croak "Missing `$_` mandatory parameter"
            unless exists $params{ $_ };
    }

    unless ( $params{store} ) {
        warn "Missing `store` parameter\n"
            if $params{debug};
        $params{store} = 'pause_recent.data';
    }
    
    unless ( $params{ua_args} ) {
        $params{ua_args}{timeout} = 30;
    }
    
    eval { $params{recent_data} = retrieve $params{store}; };
    if ( $@ and $params{debug} ) {
        warn "Failed to load data from `$params{store}`. This is"
            . " normal if the file didn't exist before\n";
    }
    
    my $self = bless \%params, $class;

     $self->{recent_poco}
        = POE::Component::WWW::PAUSE::RecentUploads->spawn(
         login   => $self->{login},
         pass    => $self->{pass},
         ua_args => $self->{ua_args},
         debug   => exists $self->{debug} ? $self->{debug} : 0,
     );
    
    $self->{session_id} = POE::Session->create(
        object_states => [
            $self => {
                fetch         => '_fetch',
                shutdown      => '_shutdown',
                stop_interval => '_stop_interval',
            },
            $self => [
                qw(
                    _got_recent
                    _ask_recent
                    _start
                )
            ],
        ],
        ( exists $params{options} ? ( options => $params{options} ) : () ),
    )->ID;

    return $self;
}

sub _start {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];
    $self->{session_id} = $_[SESSION]->ID();

    if  ( $self->{alias} ) {
        $kernel->alias_set( $self->{alias} );
    }
    else {
        $kernel->refcount_increment( $self->{session_id} => __PACKAGE__ );
    }

}

sub shutdown {
    my $self = shift;
    $poe_kernel->post( $self->{session_id} => 'shutdown' );
}

sub _shutdown {
    my ( $kernel, $self ) = @_[ KERNEL, OBJECT ];      
    return
        if $self->{shutdown};
    $self->_kill_tails;
    $poe_kernel->delay('_ask_recent');
    $self->{recent_poco}->shutdown;
    $kernel->alarm_remove_all;
    $kernel->alias_remove( $_ ) for $kernel->alias_list;
    $self->{flag} = 1;
    $kernel->refcount_decrement( $self->{session_id} => __PACKAGE__ )
            unless $self->{alias};
        
    $self->{shutdown} = 1;
}


sub session_id {
    return $_[0]->{session_id};
}
sub stop_interval {
    my $self = shift;
    $poe_kernel->yield( $self->{session_id} => 'stop_interval' => @_ );
}

sub _stop_interval {
    my ( $kernel, $self, $req_id ) = @_[ KERNEL, OBJECT, ARG0 ];
    my $flag = $self->{flags}{ $req_id };
    
    if ( $flag ) {
        $kernel->alarm_remove( $flag->{delay} )
            if exists $flag->{delay};
        $kernel->refcount_decrement( $flag->{sender} => __PACKAGE__ );
        delete $self->{flags}{ $req_id };
    }
    else {
        $self->_kill_tails;
    }
}

sub _kill_tails {
    my $self = shift;
    foreach my $req_id ( keys %{ $self->{flags} } ) {
        my $flag = $self->{flags}{ $req_id };
        $poe_kernel->alarm_remove( $flag->{delay} )
            if exists $flag->{delay};
            
        $poe_kernel->refcount_decrement( $flag->{sender} => __PACKAGE__ );
    }
    $self->{flags} = {};
}

sub fetch {
    my $self = shift;
    $poe_kernel->post( $self->{session_id} => 'fetch' => @_ );
}

sub _fetch {
    my ( $kernel, $self, $args) = @_[ KERNEL, OBJECT, ARG0 ];
    
    my $sender = $_[SENDER]->ID;
    
    unless ( exists $args->{event} ) {
        warn "Missing `event` argument";
        return;
    }
    
    if ( $args->{session} ) {
        if ( my $ref = $kernel->alias_resolve( $args->{session} ) ) {
            $args->{sender} = $ref->ID;
        }
        else {
            warn "Could not resolve `session` parameter to a "
                    . "valid POE session. Aborting...";
            return;
        }
    }
    else {
        $args->{sender} = $sender;
    }
    
    if ( exists $args->{interval} ) {
        $args->{interval} = 0 + $args->{interval};
    }
    else {
        $args->{interval} = 1800;
    }

    my $req_id = rand() . time() . rand();
    my $req_flag =  {
         req_id => $req_id,
         sender => $args->{sender},
         flag   => 1,
    };
    $self->{flags}{ $req_id } = $req_flag;
    $args->{flag} = $req_id;

    $kernel->refcount_increment( $args->{sender} => __PACKAGE__ );
    $kernel->post( $self->{session_id} => '_ask_recent' => $args );
}

sub _ask_recent {
    my ( $kernel, $self, $args ) = @_[ KERNEL, OBJECT, ARG0 ];
    
    my $req_id = $args->{flag};
    my $flag = $self->{flags}{ $req_id };

    if ( $flag->{flag} ) {
        $self->{recent_poco}->fetch( {
                event => '_got_recent',
                _args => $args ,
            }
        );
        
        if ( $args->{interval} ) {
            $flag->{delay} = $kernel->delay(
                _ask_recent => $args->{interval} => $args
            );
        }
    }
}

sub _got_recent {
    my ( $kernel, $self, $input ) = @_[ KERNEL, OBJECT, ARG0 ];
    my $args = { %{ $input->{_args} } };
    my $req_id = $args->{flag};

    my $session = delete $args->{sender};
    my $event   = delete $args->{event};
    
    if ( $self->{flags}{ $req_id }{flag} ) {
        if ( $input->{error} ) {
            $args->{error} = $input->{error};
        }
        else {
            $args->{data} = $self->_make_recent_data( $input->{data} );
        }
        $args->{time} = time();
        $args->{req_id} = delete $args->{flag}; # 'flag' is a poor name :(
        
        $kernel->post( $session, $event, $args );
        
        unless ( $args->{interval} ) {
            delete $self->{flags}{ $req_id };
            $poe_kernel->refcount_decrement( $session => __PACKAGE__ );
        }
    }

    undef;
}


sub _make_recent_data {
    my ( $self, $data ) = @_;

    my $recent_dists_ref = { map { $_->{dist} => $_ } @$data };
    foreach my $stored_dist ( keys %{ $self->{recent_data} } ) {
        delete $self->{recent_data}{ $stored_dist }
            unless exists $recent_dists_ref->{ $stored_dist };
    }
    
    my @new_dists;
    foreach my $dist ( keys %$recent_dists_ref ) {
        next
            if exists $self->{recent_data}{ $dist };
        
        $self->{recent_data}{ $dist }
            = $recent_dists_ref->{ $dist };
            
        push @new_dists, $recent_dists_ref->{ $dist };
    }

    eval { store $self->{recent_data}, $self->{store}; };
    warn "Failed to store recent data into `$self->{store}` ($@)"
        if $@;

    return \@new_dists;
}

1;
__END__
# Below is stub documentation for your module. You'd better edit it!

=head1 NAME

POE::Component::WWW::PAUSE::RecentUploads::Tail - tail recent uploads
to PAUSE.

=head1 SYNOPSIS

    use strict;
    use warnings;
    
    use POE qw(Component::WWW::PAUSE::RecentUploads::Tail);
    
    POE::Component::WWW::PAUSE::RecentUploads::Tail->spawn(
        login => 'PAUSE_LOGIN',
        pass  => 'PAUSE_PASSWORD',
        store => 'data.file', # where to store old data
        debug => 1,
        alias => 'pause',
    );
    
    POE::Session->create(
        package_states => [
            main => [ qw( _start recent ) ],
        ],
    );
    
    $poe_kernel->run;
    
    sub _start {
        $poe_kernel->post( pause => fetch =>  {
                event => 'recent',
                interval => 600, # 10 minute interval
            }
        );
    }
    
    sub recent {
        my $data_ref = $_[ARG0];
    
        my $iter_time = localtime $data_ref->{time};
    
        
        if ( $data_ref->{error} ) {
            print "Failed on this itteration with $data_ref->{error}\n";
        }
        else {
            my $message = @{ $data_ref->{data} }
                        ? "\nNew uploads at $iter_time\n"
                        : "\nNo uploads at $iter_time\n";
            print $message;
            
            foreach my $dist ( @{ $data_ref->{data} } ) {
                printf "%s by %s (size: %s)\n",
                    @$dist{ qw( dist name size ) };
            }
        }
    }

Using the event based interface is also possible, of course.

=head1 DESCRIPTION

This module accesses the list of recent uploads on L<http://pause.perl.org>
and reports whichever it didn't report earlier.

=head1 CONSTRUCTOR

    my $poco = POE::Component::WWW::PAUSE::RecentUploads::Tail->spawn(
        login => 'PAUSE LOGIN',     # mandatory
        pass  => 'PAUSE PASSWORD',  # mandatory
    );
    
    POE::Component::WWW::PAUSE::RecentUploads::Tail->spawn(
        login => 'PAUSE LOGIN',     # mandatory
        pass  => 'PAUSE PASSWORD',  # mandatory
        store => 'storage_file.data', # this and all the rest are optional
        alias => 'recent',         
        debug   => 1,               
        ua_args => {                
            timeout => 10,
            agent   => 'RecentUA',
            # other LWP::UserAgent's constructor arguments can go here
        },
        options => {
            debug => 1, # POE::Session create() may go here.
        },
    );

Spawns a new POE::Component::WWW::PAUSE::RecentUploads::Tail component and
returns a reference to it, but you don't have to keep it if you set the
optional C<alias> argument. Takes a single argument which is a hashref of
options. Two of them, C<login> and C<password> are mandatory, the rest
is optional. The possible keys/values are as follows:

=head2 login

    { login => 'PAUSE LOGIN' }

B<Mandatory>. Must contain your L<http://pause.perl.org> login.

=head2 pass

    { login => 'PAUSE LOGIN' }

B<Mandatory>. Must contain your L<http://pause.perl.org> password.

=head2 store

    { store => 'storage_file.data' }
    
    { store => '/tmp/storage_file.data' }

B<Optional>. Specifies the filename of the file where we are going to
store the already reported modules. B<Defaults to:> C<pause_recent.data> in
the current directory.

=head2 alias

    { alias => 'recent' }

B<Optional>. Specifies the component's L<POE::Session> alias of the
component.

=head2 debug

B<Optional>.

Enables output of some debug messages (usually not very useful).

=head2 ua_args

    { debug   => 1 }

B<Optional>. When set to a true value will make the component emit some
debuging info. B<Defaults to:> C<0>.

=head2 options

    {
        options => {
            trace   => 1,
            default => 1,
        }
    }

A hashref of POE Session options to pass to the component's session.

=head1 METHODS

These are the object-oriented methods of the component.

=head2 fetch

    $poco->fetch( { event => 'recent' } );
       
    $poco->fetch(   {
            event     => 'recent', # the only mandatory argument
            interval  => 600,      # 10 minute interval
            login     => 'other_login', # this and below is optional
            pass      => 'other_pass',
            session   => 'other_session',
            ua_args   => {
                timeout => 10, # default timeout is 30.
                argent  => 'LolFetcher',
            },
            _user1    => 'random',
            _cow      => 'meow',
        }
    );

Instructs the component to fetch information about recent PAUSE uploads.
See C<fetch> event description below for more information.

=head2 stop_interval

    $poco->stop_interval;
    
    $poco->stop_interval( $req_id );

The C<stop_interval> method stops an already running request (which is
started with C<fetch> method/event). The output
of each itteration will contain a C<req_id> key (see OUTPUT section) which
you may pass as an optional argument to the method. When no arguments
are specified stops all currently running requests.

=head2 session_id

    my $fetcher_id = $poco->session_id;

Takes no arguments. Returns POE Session ID of the component.

=head2 shutdown

    $poco->shutdown;

Takes no arguments. Shuts the component down.

=head1 ACCEPTED EVENTS

The interaction with the component is also possible via event based
interface. The following events are accepted by the component:

=head2 fetch

    $poco->fetch( { event => 'recent' } );
       
    $poco->fetch(   {
            event     => 'recent', # the only mandatory argument
            interval  => 600,      # 10 minute interval
            login     => 'other_login', # this and below is optional
            pass      => 'other_pass',
            session   => 'other_session',
            ua_args   => {
                timeout => 10, # default timeout is 30.
                argent  => 'LolFetcher',
            },
            _user1    => 'random',
            _cow      => 'meow',
        }
    );

Takes one argument which is a hashref with the following keys:

=head3 event

    { event   => 'event_where_to_send_output' }

B<Mandatory>. The name of the event which to send when output is ready.
See OUTPUT section for its format.

=head3 interval

    { interval  => 600 }

B<Optional>. Specifies the interval in I<seconds> between requests to
PAUSE for fresh list. If specified to C<0> will make the component only
fire a single shot request without setting any interval. B<Defaults to:>
C<1800> (30 minutes)

=head3 session

    { session => 'other_session_alias' }

    { session => $other_session_ID }
    
    { session => $other_session_ref }

B<Optional>. Specifies an alternative POE Session to send the output to.
Accepts either session alias, session ID or session reference. B<Defaults
to> the current session.

=head3 login

    { login   => 'some_other_login' }

B<Optional>.Using C<login> argument you may override the PAUSE login 
you've specified
in the constructor. B<Defaults to:> contructor's C<login> value.

=head3 pass

    { pass    => 'some_other_password' }

B<Optional>. Using C<pass> argument you may override the PAUSE 
password you've specified
in the constructor. B<Defaults to:> contructor's C<pass> value.

=head3 ua_args

    {
        ua_args => {
            timeout => 10, # defaults to 30
            agent   => 'SomeUA',
            # the rest of LWP::UserAgent contructor arguments
        },
    }

B<Optional>. The C<ua_args> key takes a hashref as a value which should
contain the arguments which will
be passed to
L<LWP::UserAgent> contructor. I<Note:> all arguments will B<default to>
whatever L<LWP::UserAgent> default contructor arguments are except for
the C<timeout>, which will default to 30 seconds.

=head3 user defined arguments

    {
        _user_var    => 'foos',
        _another_one => 'bars',
        _some_other  => 'beers',
    }

B<Optional>. Any keys beginning with the C<_> (underscore) will be present
in the output intact. If C<where> option (see below) is specified, any
arguments will also be present in the result of "finished downloading"
event.


=head2 stop_interval

    $poe_kernel->post( recent => 'stop_interval' );
    
    $poe_kernel->post( recent => 'stop_interval' => $req_id );

The C<stop_interval> method stops an already running request (which is
started with C<fetch> method/event). The output
of each itteration will contain a C<req_id> key (see OUTPUT section) which
you may pass as an optional argument to the method. When no arguments
are specified stops all currently running requests.

=head2 shutdown

    $poe_kernel->post( recent => 'shutdown' );

Takes no arguments, instructs the component to shut itself down.

=head1 OUTPUT

    $VAR1 = {
        'data' => [
            {
                'name' => 'PEVANS',
                'dist' => 'Socket-GetAddrInfo-0.08_6',
                'size' => '11502b'
            },
            {
            'name' => 'JROBINSON',
            'dist' => 'SQL-Translator-0.0899_02',
            'size' => '551090b'
            },
        ],
        'time' => 1202002776,
        'req_id' => '0.27891249752520212020027750.348456874580251',
        'interval' => 600,
        '_user_key' => 'user_data'
    };

The event handler set up to listen for the event, name of which you've
specified in the C<event> argument of C<fetch> event/method will
recieve the results in C<ARG0> in the form of a hashref with one or
more of the keys presented below. The keys of the output hashref are
as follows:

=head2 data

    {
        'data' => [
                {
                'name' => 'CJUKUO',
                'dist' => 'AIIA-GMT-0.01',
                'size' => '33428b'
                },
                {
                'name' => 'DOMQ',
                'dist' => 'Alien-Selenium-0.07',
                'size' => '1640987b'
                },
            # more of these here
        ],
    }

Unless an error occured, the C<data> key will be present and the value
of it will be an arrayref of hashrefs representing recent uploads to PAUSE.
The keys of those hashrefs are as follows:

=head3 name

    { 'name' => 'CJUKUO' }

The author ID of the upload. I<Note:> often ID will show up on PAUSE
a bit later than the upload itself. If author's ID is missing the component
will ignore this upload and will report it later.

=head3 dist

    { 'dist' => 'Alien-Selenium-0.07' }

The name of the distro (or file if you prefer) that was uploaded.

=head3 size

    { 'size' => '1640987b' }

The size of the uploaded file. The value will also contain the unit of
measure.

=head2 error

    { 'error' => '401 Authorization Required' }

If an error occured the C<error> key will be present and will contain
the description of the error.

=head2 time

    { 'time' => 1202002776 }
    
    my $request_time = localtime $data_ref->{time};

Will contain the output of Perl's C<time> function which will be the 
time of the request.

=head2 req_id
 
    { 'req_id' => '0.27891249752520212020027750.348456874580251' }

The C<req_id> key will contain the ID of your request. You can use in
in the C<stop_interval()> event/method to stop your request.

=head2 interval

    { 'interval' => 600 }

The C<interval> key will contain the interval of request recurrance
in seconds. This is basically whatever you've specified in the C<fetch()>
event/method.

=head2 user defined arguments

    {
        _user_var    => 'foos',
        _another_one => 'bars',
        _some_other  => 'beers',
    }

B<Optional>. Any keys beginning with the C<_> (underscore) will be present
in the output intact.

=head1 PREREQUISITES

This module requires the following modules/version for proper operation:

        Carp                                      => 1.04,
        POE                                       => 0.9999,
        POE::Component::WWW::PAUSE::RecentUploads => 0.01,
        Storable                                  => 2.15,

Not tested with earlier versions of those modules, but it might work.

=head1 SEE ALSO

L<WWW::PAUSE::RecentUpload>, L<POE::Component::WWW::PAUSE::RecentUploads>,
L<POE::Component::IRC::Plugin::PAUSE::RecentUploads>,
L<http://pause.perl.org>

=head1 AUTHOR

Zoffix Znet, C<< <zoffix at cpan.org> >>

=head1 BUGS

Please report any bugs or feature requests to C<bug-poe-component-www-pause-recentupoads-tail at rt.cpan.org>, or through
the web interface at L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=POE-Component-WWW-PAUSE-RecentUpoads-Tail>.  I will be notified, and then you'll
automatically be notified of progress on your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc POE::Component::WWW::PAUSE::RecentUpoads::Tail

You can also look for information at:

=over 4

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=POE-Component-WWW-PAUSE-RecentUpoads-Tail>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/POE-Component-WWW-PAUSE-RecentUpoads-Tail>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/POE-Component-WWW-PAUSE-RecentUpoads-Tail>

=item * Search CPAN

L<http://search.cpan.org/dist/POE-Component-WWW-PAUSE-RecentUpoads-Tail>

=back

=head1 COPYRIGHT & LICENSE

Copyright 2008 Zoffix Znet, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

