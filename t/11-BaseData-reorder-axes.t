#  Tests for basedata re-ordering of label axes

use strict;
use warnings;
use 5.010;

use English qw { -no_match_vars };
use Carp;

use rlib;

local $| = 1;

use Test2::V0;

use Biodiverse::TestHelpers qw /:basedata/;
use Biodiverse::BaseData;

exit main( @ARGV );

sub main {
    my @args  = @_;

    if (@args) {
        for my $name (@args) {
            die "No test method test_$name\n"
                if not my $func = (__PACKAGE__->can( 'test_' . $name ) || __PACKAGE__->can( $name ));
            $func->();
        }
        done_testing;
        return 0;
    }
    

    test_reorder_axes();
    test_drop_axis();
    test_reorder_axes_non_symmetric_gp_axes();

    done_testing;
    return 0;
}


sub test_drop_axis {
    my $bd_base = Biodiverse::BaseData->new (
        NAME       => 'bzork',
        CELL_SIZES => [1, 10, 100],
    );
    
    foreach my $i (1..10) {
        my $gp = join ':', $i-0.5, $i*10-5, $i*100-50;
        my $lb = join '_:', $i-0.5, $i*10-5, $i*100-50;
        $bd_base->add_element (
            group => $gp,
            label => $lb,
        );
    }
    
    my (@res, @origin, $gp, $lb);
    
    my $bd = $bd_base->clone;
    
    $lb = $bd->get_labels_ref;
    $gp = $bd->get_groups_ref;    
    is ($lb->get_axis_count, 3, 'got expected label axis count');
    is ($gp->get_axis_count, 3, 'got expected group axis count');

    #  some fails
    ok (dies 
        {$bd->drop_element_axis (axis => 20, type => 'label')},
        'axis too large',
    ) or note $@;
    ok (dies 
        {$bd->drop_element_axis (axis => -20, type => 'label')},
        'neg axis too large',
    ) or note $@;
    ok (dies
        {$bd->drop_element_axis (axis => 'glert', type => 'label')},
        'non-numeric axis',
    ) or note $@;
    
    $bd->drop_element_axis (axis => 2, type => 'label');
    is ($lb->get_axis_count, 2, 'label axis count reduced');
    @res = $lb->get_cell_sizes;
    is ($#res, 1, 'label cell size array');
    @origin = $lb->get_cell_origins;
    is ($#origin, 1, 'label cell origins');
    
    $lb = $bd->get_labels_ref;
    $gp = $bd->get_groups_ref;    
    is ($lb->get_axis_count, 2, 'got expected label axis count after deletion');
    
    ok ($bd->exists_label_aa ('0.5_:5_'), 'check label exists');

    $bd = $bd_base->clone;
    $lb = $bd->get_labels_ref;
    $gp = $bd->get_groups_ref;
    
    $bd->drop_element_axis (axis => 1, type => 'group');
    is ($gp->get_axis_count, 2, 'group axis count reduced');
    @res = $gp->get_cell_sizes;
    is ($#res, 1, 'group cell size array');
    @origin = $gp->get_cell_origins;
    is ($#origin, 1, 'group cell origins');
    is ($gp->get_axis_count, 2, 'got expected group axis count after deletion');

    ok ($bd->exists_group_aa ('0.5:50'), 'check group exists');
    $bd->drop_element_axis (axis => 0, type => 'group');
    ok ($bd->exists_group_aa ('50'), 'check group exists, second deletion');
    
    my $orig_samp_count = $bd_base->get_label_sample_count (element => '0.5_:5_:50_');
    my $new_samp_count  = $bd->get_label_sample_count (element => '0.5_:5_');
    is ($new_samp_count, $orig_samp_count, "Label sample counts match after dropped axis");

    ok (dies
        {$bd->drop_element_axis (axis => 0, type => 'group')},
        'dies if no axes will be left',
    ) or note $@;

    my $bd_with_outputs = $bd_base->clone;
    my $sp = $bd_with_outputs->add_spatial_output (name => 'spatialisationater');
    $sp->run_analysis (
        spatial_conditions => ['sp_self_only()'],
        calculations       => ['calc_richness'],
    );
    ok ( dies
        {$bd_with_outputs->drop_element_axis (axis => 1, type => 'label')},
        'dies with existing outputs',
    ) or note $@;
    

    $bd = $bd_base->clone;
    $lb = $bd->get_labels_ref;
    $gp = $bd->get_groups_ref;
    
    $bd->drop_group_axis (axis => 1);
    is ($gp->get_axis_count, 2, 'group axis count reduced');
    @res = $gp->get_cell_sizes;
    is ($#res, 1, 'group cell size array');
    @origin = $gp->get_cell_origins;
    is ($#origin, 1, 'group cell origins');
    is ($gp->get_axis_count, 2, 'got expected group axis count after deletion');
    my $bd_cell_sizes = $bd->get_cell_sizes;
    my $gp_cell_sizes = $gp->get_cell_sizes;
    is $bd_cell_sizes, $gp_cell_sizes, 'basedata matches group cell sizes';
}



sub _repeat_test_reorder_axes {
    test_reorder_axes() for (1..1000);
}

#  reordering of axes
sub test_reorder_axes {
    my $bd = eval {
        get_basedata_object (
            x_spacing  => 1,
            y_spacing  => 1,
            CELL_SIZES => [1, 2],
            CELL_ORIGINS => [2, 1],
            x_max      => 10,
            y_max      => 10,
            x_min      => 0,
            y_min      => 0,
            use_rand_counts => 1,
        );
    };
    croak $@ if $@;

    my $test_label = '0_0';
    my $lb_props = {blah => 25, blahblah => 10};
    my $lb = $bd->get_labels_ref;
    $lb->add_to_lists (
        element    => $test_label,
        PROPERTIES => $lb_props,
    );
    my $test_group_orig = '0.5:2';
    my $test_group_new  = '2:0.5';
    my $gp_props = {blah => 25, blahblah => 10};
    my $gp = $bd->get_groups_ref;
    $gp->add_to_lists (
        element    => $test_group_orig,
        PROPERTIES => $gp_props,
    );

    my $new_bd = eval {
        $bd->new_with_reordered_element_axes (
            GROUP_COLUMNS => [1,0],
            LABEL_COLUMNS => [0],
        );
    };
    my $error = $EVAL_ERROR;
    warn $error if $error;

    ok (defined $new_bd, 'Reordered axes');

    is (scalar $new_bd->get_cell_sizes,   [2,1], 'Cell sizes reversed');
    is (scalar $new_bd->get_cell_origins, [1,2], 'Cell origins reversed');

    my (@got_groups, @orig_groups, @got_labels, @orig_labels);
    eval {
        @got_groups  = $new_bd->get_groups;
        @orig_groups = $bd->get_groups;
        @got_labels  = $new_bd->get_labels;
        @orig_labels = $bd->get_labels;
    };
    diag $@ if $@;

    is (scalar @got_groups, scalar @orig_groups, 'same group count');
    is (scalar @got_labels, scalar @orig_labels, 'same label count');

    my ($orig, $new);
    
    my $type = 'sample counts';
    $orig = $bd->get_group_sample_count (element => '0.5:1.5');
    eval {
        $new  = $new_bd->get_group_sample_count (element => '1.5:0.5');
    };
    diag $@ if $@;

    is ($new, $orig, "Group $type match");
    
    $orig = $bd->get_label_sample_count (element => $test_label);
    $new  = $new_bd->get_label_sample_count (element => $test_label);
    is ($new, $orig, "Label $type match");

    #  Need more tests of variety, range, properties etc.
    #  But first need to modify the basedata creation subs to give differing
    #  results per element.  This requires automating the elements used
    #  for comparison (i.e. not hard coded '0.5:1.5', '1.5:0.5')

    #  test label and group properties
    #  (should make more compact using a loop)
    my ($props, $el_ref);

    $el_ref = $new_bd->get_groups_ref;
    $props = $el_ref->get_list_values (
        element => $test_group_new,
        list    => 'PROPERTIES'
    );
    while (my ($key, $value) = each %$gp_props) {
        is ($value, $props->{$key}, "Group remapped $key == $value");
    }

    $el_ref = $new_bd->get_labels_ref;
    $props = $el_ref->get_list_values (
        element => $test_label,
        list    => 'PROPERTIES'
    );
    while (my ($key, $value) = each %$lb_props) {
        is ($value, $props->{$key}, "Label remapped $key == $value");
    }
    
}

#  reordering of axes
sub test_reorder_axes_non_symmetric_gp_axes {
    my $bd = Biodiverse::BaseData->new (
        CELL_SIZES   => [1,2],
        CELL_ORIGINS => [1,2],
        NAME => 'test_reorder_axes_non_symmetric_gp_axes',
    );
    my $smp_count = 0;
    foreach my $row (0..10) {
        foreach my $col (0..10) {
            $smp_count++;
            my $gp_id = join ':', $row + 0.5, 2 * POSIX::floor ($col / 2) + 1;
            my $lb_id = join ':', $row, $col;
            #diag "$gp_id, $row, $col";
            $bd->add_element (
                group => $gp_id,
                label => $lb_id,
                sample_count => $smp_count,
            );
        }        
    }

    my $test_label = '0:0';
    my $lb_props = {blah => 25, blahblah => 10};
    my $lb = $bd->get_labels_ref;
    $lb->add_to_lists (
        element    => $test_label,
        PROPERTIES => $lb_props,
    );
    my $test_group_orig = '0.5:1';
    my $test_group_new  = '1:0.5';
    my $gp_props = {blah => 25, blahblah => 10};
    my $gp = $bd->get_groups_ref;
    $gp->add_to_lists (
        element    => $test_group_orig,
        PROPERTIES => $gp_props,
    );

    my $new_bd = eval {
        $bd->new_with_reordered_element_axes (
            GROUP_COLUMNS => [1,0],
            LABEL_COLUMNS => [0,1],
        );
    };
    my $error = $EVAL_ERROR;
    warn $error if $error;

    ok (defined $new_bd, 'Reordered axes');
    
    my $new_cell_sizes  = $new_bd->get_cell_sizes;
    is ($new_cell_sizes, [2,1], 'cell sizes updated');
    my $new_cell_origins  = $new_bd->get_cell_origins;
    is ($new_cell_origins, [2,1], 'cell origins updated');

    my (@got_groups, @orig_groups, @got_labels, @orig_labels);
    eval {
        @got_groups  = $new_bd->get_groups;
        @orig_groups = $bd->get_groups;
        @got_labels  = $new_bd->get_labels;
        @orig_labels = $bd->get_labels;
    };
    diag $@ if $@;

    is (scalar @got_groups, scalar @orig_groups, 'same group count');
    is (scalar @got_labels, scalar @orig_labels, 'same label count');

    my ($orig, $new);
    
    my $type = 'sample counts';
    $orig = $bd->get_group_sample_count (element => '0.5:1');
    eval {
        $new  = $new_bd->get_group_sample_count (element => '1:0.5');
    };
    diag $@ if $@;

    is ($new, $orig, "Group $type match");
    
    $orig = $bd->get_label_sample_count (element => $test_label);
    $new  = $new_bd->get_label_sample_count (element => $test_label);
    is ($new, $orig, "Label $type match");

}

done_testing();
