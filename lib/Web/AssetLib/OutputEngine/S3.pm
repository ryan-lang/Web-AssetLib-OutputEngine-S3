package Web::AssetLib::OutputEngine::S3;

# ABSTRACT: S3 output engine for Web::AssetLib
our $VERSION = "0.03";

use strict;
use warnings;
use Kavorka;
use Moo;
use Carp;
use Paws;
use Paws::Credential::Environment;
use Types::Standard qw/Str InstanceOf HashRef/;
use Web::AssetLib::Output::Link;

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

has 'region' => (
    is       => 'rw',
    isa      => Str,
    required => 1
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
    my $types  = {};
    my $output = [];

    # categorize into type groups, and seperate concatenated
    # assets from those that stand alone

    foreach my $asset ( sort { $a->rank <=> $b->rank } @$assets ) {
        if ( $asset->isPassthru ) {
            push @$output,
                Web::AssetLib::Output::Link->new(
                src  => $asset->link_path,
                type => $asset->type
                );
        }
        else {
            for ( $asset->type ) {
                when (/css|js/) {

                    # should concatenate
                    $$types{ $asset->type }{_CONCAT_}
                        .= $asset->contents . "\n\r\n\r";
                }
                default {
                    $$types{ $asset->type }{ $asset->digest }
                        = $asset->contents;
                }
            }
        }
    }

    my $cacheInvalid = 0;
    foreach my $type ( keys %$types ) {
        foreach my $id ( keys %{ $$types{$type} } ) {
            my $output_contents = $$types{$type}{$id};

            my $digest
                = $id eq '_CONCAT_'
                ? $self->generateDigest($output_contents)
                : $id;

            my $filename = "assets/$digest.$type";
            if ( $self->_s3_obj_cache->{$filename} ) {
                $self->log->debug("found asset in cache: $filename");
            }
            else {
                $self->log->debug("generating new asset: $filename");
                if ($minifier) {
                    $output_contents = $minifier->minify(
                        contents => $output_contents,
                        type     => $type
                    );
                }

                my $put = $self->s3->PutObject(
                    Bucket => $self->bucket_name,
                    Key    => $filename,
                    Body   => $output_contents,
                    ContentType =>
                        Web::AssetLib::Util::normalizeMimeType($type)
                );

                $cacheInvalid = 1;
            }

            push @$output,
                Web::AssetLib::Output::Link->new(
                src  => sprintf( '%s/%s', $self->link_url, $filename ),
                type => $type
                );
        }
    }

    $self->_invalidate_s3_obj_cache()
        if $cacheInvalid;

    return $output;
}

method _build__s3_obj_cache (@_) {
    my $results = $self->s3->ListObjects( Bucket => $self->bucket_name );
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

=encoding utf-8
 
=head1 AUTHOR
 
Ryan Lang <rlang@me.com>
 
=cut
