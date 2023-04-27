package Biodiverse::Metadata::BaseStruct;
use strict;
use warnings;
use 5.016;
use Carp;
use Readonly;

our $VERSION = '4.3';

use parent qw /Biodiverse::Metadata/;


my %methods_and_defaults = (
    types => [],
);


sub _get_method_default_hash {
    return wantarray ? %methods_and_defaults : {%methods_and_defaults};
}


__PACKAGE__->_make_access_methods (\%methods_and_defaults);



1;
