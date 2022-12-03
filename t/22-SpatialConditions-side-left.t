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
    sides => {
        'sp_is_left_of()' => 420,
        'sp_is_left_of(vector_angle => 0)' => 420,
        'sp_is_left_of(vector_angle => Math::Trig::pip2)' => 450,
        'sp_is_left_of(vector_angle => Math::Trig::pip4)' => 435,
        'sp_is_left_of(vector_angle_deg => 0)'  => 420,
        'sp_is_left_of(vector_angle_deg => 45)' => 435,
        'sp_is_left_of(vector_angle_deg => 90)' => 450,
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
