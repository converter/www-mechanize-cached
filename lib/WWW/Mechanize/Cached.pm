package WWW::Mechanize::Cached;

use strict;
use warnings FATAL => 'all';

=head1 NAME

WWW::Mechanize::Cached - Cache response to be polite

=head1 VERSION

Version 1.33

=cut

use vars qw( $VERSION );
$VERSION = '1.33';

=head1 SYNOPSIS

    use WWW::Mechanize::Cached;

    my $cacher = WWW::Mechanize::Cached->new;
    $cacher->get( $url );

=head1 DESCRIPTION

Uses the L<Cache::Cache> hierarchy to implement a caching Mech. This
lets one perform repeated requests without hammering a server impolitely.

Repository: L<http://github.com/oalders/www-mechanize-cached/tree/master>

=cut

use base qw( WWW::Mechanize );
use Carp qw( carp croak );
use Storable qw( freeze thaw );

my $cache_key = __PACKAGE__;

=head1 CONSTRUCTOR

=head2 new

Behaves like, and calls, L<WWW::Mechanize>'s C<new> method.  Any parms
passed in get passed to WWW::Mechanize's constructor.

You can pass in a C<< cache => $cache_object >> if you want.  The
I<$cache_object> must have C<get()> and C<set()> methods like the
C<Cache::Cache> family.

The I<cache> parm used to be a set of parms that described how the
cache object was to be initialized, but I think it makes more sense
to have the user initialize the cache however she wants, and then
pass it in.

The I<pre_cache_fix_uri> parm is a reference to a subroutine that takes as
its argument the request URI and is expected to return a valid URI.
I<pre_cache_fix_uri> is called before the cache get and set operations.
This callback can be used to replace session keys or other strings that
appear in the URL path but are not treated as path parts by the server with
an arbitrary string so that requests across multiple sessions set or get the
same cached resource. I<response_post_cache_hook> can be used to replace
the arbitrary string with a valid session key, for example, after
fetching the response from cache.

The I<response_post_cache_hook> parm is a reference to a subroutine that
takes as its argument the HTTP::Response object fetched from cache.  This
callback can be used to modify the response URI or replace headers in the
cached response that would otherwise cause subsequent requests to fail.
Headers that fall into this category might include session ID cookie
headers.

The I<do_not_cache> parm is a reference to a subroutine that takes
the HTTP::Response object and returns true if the fetched object
should be excluded from the cache. This callback can be used to prevent
caching of error reponses that fail to include a proper response code
(500, for example).

If the I<cache_successful_only> parm is true, only responses which return true
from calls to &HTTP::Response::is_success or &HTTP::Response::is_redirect are
cached. See L<HTTP::Response> for more information.

=cut

sub new {
    my $class = shift;
    my %mech_args = @_;

    my $pre_cache_fix_uri = delete $mech_args{pre_cache_fix_uri};
    my $response_post_cache_hook = delete $mech_args{response_post_cache_hook};
    my $do_not_cache = delete $mech_args{do_not_cache};
    my $cache_successful_only = delete $mech_args{cache_successful_only};
    if ($pre_cache_fix_uri) {
        unless (ref $pre_cache_fix_uri eq 'CODE') {
            croak "'pre_cache_fix_uri' parm must be a reference to a subroutine";
        }
    }
    if ($response_post_cache_hook) {
        unless (ref $response_post_cache_hook eq 'CODE') {
            croak "'response_post_cache_hook' parm must be a reference to a subroutine";
        }
    }
    if ($do_not_cache) {
        unless (ref $do_not_cache eq 'CODE') {
            croak "'do_not_cache' parm must be a reference to a subroutine";
        }
    }

    my $cache = delete $mech_args{cache};
    if ( $cache ) {
        my $ok = (ref($cache) ne "HASH") && $cache->can("get") && $cache->can("set");
        if ( !$ok ) {
            carp "The cache parm must be an initialized cache object";
            $cache = undef;
        }
    }

    my $self = $class->SUPER::new( %mech_args );

    if ( !$cache ) {
        require Cache::FileCache;
        my $cache_parms = {
            default_expires_in => "1d",
            namespace => 'www-mechanize-cached',
        };
        $cache = Cache::FileCache->new( $cache_parms );
    }

    $self->{$cache_key} = $cache;
    $self->{pre_cache_fix_uri} = $pre_cache_fix_uri;
    $self->{response_post_cache_hook} = $response_post_cache_hook;
    $self->{do_not_cache} = $do_not_cache;
    $self->{cache_successful_only} = $cache_successful_only;

    return $self;
}

=head1 METHODS

Most methods are provided by L<WWW::Mechanize>. See that module's
documentation for details.

=head2 disable_cache()

Disable cache storage. All subsequent requests will ignore the cache entirely.

=head2 enable_cache()

Enable cache storage. All subsequent requests will attempt to fetch the
response from cache before submitting the request to the server.

NOTE: The cache is enabled by default, and can only be disabled by a call
to disable_cache().

=head2 is_cached()

Returns true if the current page is from the cache, or false if not.
If it returns C<undef>, then you don't have any current request.

=cut

sub is_cached {
    my $self = shift;

    return $self->{_is_cached};
}

sub disable_cache {
    my $self = shift;
    $self->{__cache_disabled} = 1;
    return;
}

sub enable_cache {
    my $self = shift;
    delete $self->{__cache_disabled};
    return;
}

sub cache_enabled { $_[0]->{__cache_disabled} ? 0 : 1 }

sub _make_request {
    my $self = shift;
    my $request = shift;

    my $cache = $self->{$cache_key};
    my $key;

    if ($self->{pre_cache_fix_uri}) {
        # make a clone because we can't change the URI of the original,
        # which would make the request point at an invalid resource.
        my $clone = $request->clone;
        $clone->uri($self->{pre_cache_fix_uri}->($clone->uri));
        $key = $clone->as_string;
    }
    else {
        $key = $request->as_string;
    }

    my $response;

    unless ($self->{__cache_disabled}) {
        $response = $cache->get( $key );
    }

    if ( $response ) {
        $response = thaw $response;
        if ($self->{response_post_cache_hook}) {
            $self->{response_post_cache_hook}->($response);
        }
        $self->{_is_cached} = 1;
    } else {
        $response = $self->SUPER::_make_request( $request, @_ );
        
        # http://rt.cpan.org/Public/Bug/Display.html?id=42693
        $response->decode();
        delete $response->{handlers};

        unless ($self->{do_not_cache} && $self->{do_not_cache}->($response)) {
            if ($self->{cache_successful_only}) {
                if ($response->is_success || $response->is_redirect) {
                    $cache->set( $key, freeze($response) );
                }
            }
            else {
                $cache->set( $key, freeze($response) );
            }
        }
        $self->{_is_cached} = 0;
    }

    # An odd line to need.
    $self->{proxy} = {} unless defined $self->{proxy};

    return $response;
}



=head1 THANKS

Iain Truskett for writing this in the first place.

=head1 BUGS AND LIMITATIONS

It may sometimes seem as if it's not caching something. And this
may well be true. It uses the HTTP request, in string form, as the key
to the cache entries, so any minor changes will result in a different
key. This is most noticable when following links as L<WWW::Mechanize>
adds a C<Referer> header.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc WWW::Mechanize::Cached

You can also look for information at:

=over 4

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/WWW-Mechanize-Cached>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/WWW-Mechanize-Cached>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=WWW-Mechanize-Cached>

=item * Search CPAN

L<http://search.cpan.org/dist/WWW-Mechanize-Cached>

=back


=head1 LICENSE AND COPYRIGHT

This module is copyright Iain Truskett and Andy Lester, 2004. All rights
reserved.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.000 or,
at your option, any later version of Perl 5 you may have available.

The full text of the licences can be found in the F<Artistic> and
F<COPYING> files included with this module, or in L<perlartistic> and
L<perlgpl> as supplied with Perl 5.8.1 and later.

=head1 AUTHOR

Iain Truskett <spoon@cpan.org>

Maintained from 2004 - July 2009 by Andy Lester <petdance@cpan.org>

Currently maintained by Olaf Alders <olaf@wundercounter.com>

=head1 SEE ALSO

L<WWW::Mechanize>.

=cut

"We miss you, Spoon"; ## no critic
