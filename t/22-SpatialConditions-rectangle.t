use strict;
use warnings;
use Carp;
use English qw { -no_match_vars };

use FindBin qw/$Bin/;

use rlib;
use Test2::V0;

use Scalar::Util qw /looks_like_number/;
use Data::Dumper qw /Dumper/;

local $| = 1;

use Biodiverse::TestHelpers qw {:spatial_conditions};
use Biodiverse::BaseData;
use Biodiverse::SpatialConditions;

#  need to build these from tables
#  need to add more
#  the ##1 notation is odd, but is changed for each test using regexes
my %conditions = (
    rectangle => {
        'sp_rectangle (sizes => [##1, ##1])' =>  1,
        'sp_rectangle (sizes => [##2, ##2])' =>  9,
        'sp_rectangle (sizes => [##3, ##3])' =>  9,
        'sp_rectangle (sizes => [##4, ##4])' => 25,
        'sp_rectangle (sizes => [##6, ##2])' => 21,
        'sp_rectangle (sizes => [##2, ##6])' => 21,
        'sp_rectangle (sizes => [##2, ##6], axes => [1, 0])' => 21,
        'sp_rectangle (sizes => [##2, ##6], axes => [0, 1])' => 21,
    },
);


exit main( @ARGV );

sub main {
    my @args  = @_;

    my @res_pairs = get_sp_cond_res_pairs_to_use (@args);
    my %conditions_to_run = get_sp_conditions_to_run (\%conditions, @args);

    foreach my $key (sort keys %conditions_to_run) {
        #diag $key;
        test_sp_cond_res_pairs ($conditions{$key}, \@res_pairs);
    }

    done_testing;
    return 0;
}
