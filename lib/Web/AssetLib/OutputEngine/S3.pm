package Web::AssetLib::OutputEngine::S3;

# ABSTRACT: AWS S3 output engine for Web::AssetLib
our $VERSION = "0.07";

use strict;
use warnings;
use Kavorka;
use Moo;
use Carp;
use DateTime;
use Paws;
use Paws::Credential::Environment;
use Types::Standard qw/Str InstanceOf HashRef Maybe CodeRef/;
use Web::AssetLib::Output::Link;
use DateTime::Format::HTTP;

extends 'Web::AssetLib::OutputEngine';

use feature 'switch';
no if $] >= 5.018, warnings => "experimental";

has [qw/access_key secret_key/] => (
    is       => 'rw',
    isa      => Str,
    required => 1
);

has 'bucket_name' => (
    is       => 'rw',
    isa      => Str,
    required => 1
);

# optional unique identifier -
# if provided, assets will be placed
# in this subdirectory
has 'bucket_uuid' => (
    is        => 'rw',
    isa       => Maybe [Str],
    predicate => 'has_bucket_uuid'
);

has 'region' => (
    is       => 'rw',
    isa      => Str,
    required => 1
);

# undef means no expiration tag is set
# callback recieves a hashref of put arguments
# and should return DateTime object
has 'object_expiration_cb' => (
    is      => 'rw',
    isa     => Maybe [CodeRef],
    default => sub {
        sub {
            my $args = shift;
            return DateTime->now( time_zone => 'local' )->add( years => 1 );
        };
    }
);

has 'link_url' => (
    is       => 'rw',
    isa      => Str,
    required => 1
);

has 's3' => (
    is      => 'rw',
    isa     => InstanceOf ['Paws::S3'],
    lazy    => 1,
    default => sub {
        my $self = shift;
        return Paws->service(
            'S3',
            credentials => Paws::Credential::Environment->new(
                access_key => $self->access_key,
                secret_key => $self->secret_key
            ),
            region => $self->region
        );
    }
);

has '_s3_obj_cache' => (
    is      => 'lazy',
    isa     => HashRef,
    clearer => '_invalidate_s3_obj_cache',
    builder => '_build__s3_obj_cache'
);

method export (:$assets!, :$minifier?) {
    my $output = [];

    # categorize into type groups, and seperate concatenated
    # assets from those that stand alone

    my $assets_by_type = $self->sortAssetsByType($assets);

    my $cacheInvalid = 0;
    foreach my $type ( keys %$assets_by_type ) {
        foreach my $asset ( @{ $$assets_by_type{$type} } ) {

            if ( ref($asset) && $asset->isPassthru ) {
                push @$output,
                    Web::AssetLib::Output::Link->new(
                    src  => $asset->link_path,
                    type => $type
                    );
            }
            else {
                my $contents = ref($asset) ? $asset->contents : $asset;
                my $name = ( ref($asset) ? $asset->name : undef ) // 'bundle';
                my $digest
                    = ref($asset)
                    ? $asset->digest
                    : $self->generateDigest($contents);

                my $filename;

                # use orignal filename, or generate new one
                # based on digest
                if (   ref($asset)
                    && $asset->useOriginalFilename
                    && $asset->original_filename )
                {
                    $filename = $asset->original_filename;
                }
                else {
                    $filename = "$name.$digest.$type";
                }

                # always in assets subdir
                my @path = ('assets');

                # apply output subdir, if provided
                if ( ref($asset) && $asset->output_args->{output_subdir} ) {
                    push @path, $asset->output_args->{output_subdir};
                }

                # apply bucket uuid, unless prevented or not provided
                unless (
                    (   ref($asset)
                        && $asset->output_args->{ignore_bucket_uuid}
                    )
                    || !$self->has_bucket_uuid
                    )
                {
                    push @path, $self->bucket_uuid;
                }

                my $path = join( '/', @path ) . "/";
                my $fullpath = $path . $filename;

                if ( $self->_s3_obj_cache->{$fullpath} ) {
                    $self->log->debug("found asset in cache: $fullpath");
                }
                else {
                    if ($minifier) {
                        $contents = $minifier->minify(
                            contents => $contents,
                            type     => $type
                        );
                    }

                    $self->_s3Put(
                        filename => $fullpath,
                        contents => $contents,
                        type     => $type
                    );

                    if (   ref($asset)
                        && $asset->source_map_contents
                        && length( $asset->source_map_contents ) > 0 )
                    {

                        my $srcmap_path = $path . $asset->source_map_name;
                        $self->_s3Put(
                            filename => $srcmap_path,
                            contents => $asset->source_map_contents,
                            type     => 'map'
                        );
                    }

                    $cacheInvalid = 1;
                }

                push @$output,
                    Web::AssetLib::Output::Link->new(
                    src  => sprintf( '%s/%s', $self->link_url, $fullpath ),
                    type => $type
                    );
            }
        }
    }

    $self->_invalidate_s3_obj_cache()
        if $cacheInvalid;

    return $output;
}

method _s3Put (:$filename, :$contents, :$type) {
    if ($contents) {
        my %putargs = (
            Bucket      => $self->bucket_name,
            Key         => $filename,
            Body        => $contents,
            ContentType => Web::AssetLib::Util::normalizeMimeType($type)
        );

        if ( $self->object_expiration_cb ) {
            $putargs{Expires}
                = DateTime::Format::HTTP->format_datetime(
                $self->object_expiration_cb->( \%putargs ) );
        }

        my $put = $self->s3->PutObject(%putargs);

        $self->log->debug(
            sprintf( 'emitted: %s/%s', $self->link_url, $filename ) );

        return $put;
    }
    else {
        $self->log->debug(
            "'$filename' asset was not uploaded due to empty content body");
    }
}

method _build__s3_obj_cache (@_) {
    my $results = $self->s3->ListObjects(
        Bucket => $self->bucket_name,
        Prefix => sprintf( "assets/%s",
            $self->has_bucket_uuid ? $self->bucket_uuid . "/" : "" )
    );

    my $cache = { map { $_->Key => 1 } @{ $results->Contents } };

    $self->log->dump( 's3 object cache: ', $cache, 'debug' );

    return $cache || {};
}

# before '_export' => sub {
#     my $self = shift;
#     my %args = @_;

#     $self->_validateLinks( bundle => $args{bundle} );
# };

# # check css for links to other assets, and make
# # sure they are in the bundle
# method _validateLinks (:$bundle!) {
#     foreach my $asset ( $bundle->allAssets ) {
#         next unless $asset->contents;

#         if ( $asset->type eq 'css' ) {
#             while ( $asset->contents =~ m/url\([",'](.+)[",']\)/g ) {
#                 $self->log->warn("css contains url: $1");
#             }
#         }
#     }
# }

no Moose;
1;
__END__

=pod
 
=encoding UTF-8
 
=head1 NAME

Web::AssetLib::OutputEngine::S3 - allows exporting an asset or bundle to an AWS S3 Bucket

On first usage, a cache will be generated of all files in the bucket. This way, we know
what needs to be uploaded and what's already there.

=head1 SYNOPSIS

    my $library = My::AssetLib::Library->new(
        output_engines => [
            Web::AssetLib::OutputEngine::S3->new(
                access_key  => 'AWS_ACCESS_KEY',
                secret_key  => 'AWS_SECRET_KEY',
                bucket_name => 'S3_BUCKET_NAME',
                region      => 'S3_BUCKET_REGION'
            )
        ]
    );

    $library->compile( ..., output_engine => 'S3' );

=head1 USAGE

This is an output engine plugin for L<Web::AssetLib>.

Instantiate with C<< access_key >>, C<< secret_key >>, C<< bucket_name >>, 
and C<< region >> arguments, and include in your library's output engine list.

=head1 PARAMETERS
 
=head2 access_key

=head2 secret_key
 
AWS access & secret keys. Must have C<List> and C<Put> permissions for destination bucket. 
Required.

=head2 bucket_name

S3 bucket name. Required.

=head2 region

AWS region name of the bucket. Required.

=head2 region

AWS region name of the bucket

=head2 link_url

Used as the base url of any asset that gets exported to S3. Make sure it's public!
Your CDN may go here.

=head2 object_expiration_cb

Provide a coderef used to calculate the Expiration header. Currently, 
no arguments are passed to the callback. Defaults to:

    sub {
        return DateTime->now( time_zone => 'local' )->add( years => 1 );
    };

=head1 SEE ALSO

L<Web::AssetLib>
L<Web::AssetLib::OutputEngine>

=head1 AUTHOR
 
Ryan Lang <rlang@cpan.org>

=cut

