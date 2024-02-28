package Biodiverse::Tree;

#  Package to build and store trees.
#  includes clustering methods
use 5.020;

use Carp;
use strict;
use warnings;
use Scalar::Util qw /looks_like_number blessed/;
use List::MoreUtils qw /first_index/;
use List::Util 1.54 qw /reductions sum min max uniq any/;

use Ref::Util qw { :all };
use Sort::Key qw /keysort rnkeysort rikeysort/;
use Sort::Key::Natural qw /natkeysort/;
use POSIX qw /floor ceil/;

use feature 'refaliasing';
no warnings 'experimental::refaliasing';


use English qw ( -no_match_vars );

our $VERSION = '4.99_002';

our $AUTOLOAD;

use Biodiverse::Statistics;
my $stats_class = 'Biodiverse::Statistics';

use Biodiverse::Metadata::Export;
my $export_metadata_class = 'Biodiverse::Metadata::Export';

use Biodiverse::Metadata::Parameter;
my $parameter_metadata_class = 'Biodiverse::Metadata::Parameter';

use Biodiverse::Matrix;
use Biodiverse::TreeNode;
use Biodiverse::BaseStruct;
use Biodiverse::Progress;
use Biodiverse::Exception;

use parent qw /
  Biodiverse::Common
  /;    #/

my $EMPTY_STRING = q{};

#  useful for analyses that are of type tree - could be too generic a name?
sub is_tree_object {
    return 1;
}

sub new {
    my $class = shift;

    my $self = bless {}, $class;

    my %args = @_;

    # do we have a file to load from?
    my $file_loaded;
    if ( defined $args{file} ) {
        $file_loaded = $self->load_file(@_);
    }

    return $file_loaded if defined $file_loaded;

    my %PARAMS = (    #  default params
        TYPE                 => 'TREE',
        OUTSUFFIX            => __PACKAGE__->get_file_suffix,
        OUTSUFFIX_YAML       => __PACKAGE__->get_file_suffix_yaml,
        CACHE_TREE_AS_MATRIX => 1,
    );
    $self->set_params( %PARAMS, %args );
    $self->set_default_params;    #  load any user overrides

    $self->{TREE_BY_NAME} = {};

    #  avoid memory leak probs with circular refs to parents
    #  ensures children are destroyed when parent is destroyed
    $self->weaken_basedata_ref;

    return $self;
}

sub get_file_suffix {
    return 'bts';
}

sub get_file_suffix_yaml {
    return 'bty';
}

sub rename {
    my $self = shift;
    my %args = @_;

    my $name = $args{new_name};
    if ( not defined $name ) {
        croak "[Tree] Argument 'new_name' not defined\n";
    }

    #  first tell the basedata object
    #my $bd = $self->get_param ('BASEDATA_REF');
    #$bd->rename_output (object => $self, new_name => $name);

    # and now change ourselves
    $self->set_param( NAME => $name );

}

#  need to flesh this out - total length, summary stats of lengths etc
sub _describe {
    my $self = shift;

    my @description = ( 'TYPE: ' . blessed $self, );

    my @keys = qw /
      NAME
      /;

    foreach my $key (@keys) {
        my $desc = $self->get_param ($key);
        if (is_arrayref($desc)) {
            $desc = join q{, }, @$desc;
        }
        push @description, "$key: $desc";
    }

    push @description, "Node count: " . scalar @{ $self->get_node_refs };
    push @description,
      "Terminal node count: " . scalar @{ $self->get_terminal_node_refs };
    push @description,
      "Root node count: " . scalar @{ $self->get_root_node_refs };

    push @description, "Sum of branch lengths: " . sprintf "%.6g",
      $self->get_total_tree_length;
    push @description, "Longest path: " . sprintf "%.6g",
      $self->get_longest_path_to_tip;

    my $description = join "\n", @description;

    return wantarray ? @description : $description;
}

#  sometimes we have to clean up the topology from the top down for each root node
#  this will ultimately give us a single root node where that should be the case
sub set_parents_below {
    my $self = shift;

    foreach my $node ( $self->get_node_refs ) {
        foreach my $child ( $node->get_children ) {
            $child->set_parent( parent => $node );
        }
    }

    return;
}

#  If no_delete_cache is true then the caller promises to clean up later.
#  This can be used to avoid multiple passes over the tree across multiple deletions.
sub delete_node {
    my $self = shift;
    my %args = @_;

    #  get the node ref
    my $node_ref = $self->get_node_ref_aa( $args{node} );
    return if !defined $node_ref;    #  node does not exist anyway

    #  get the names of all descendents
    my %node_hash = $node_ref->get_all_descendants( cache => 0 );
    $node_hash{ $node_ref->get_name } = $node_ref;  #  add node_ref to this list

    #  Now we delete it from the treenode structure.
    #  This cleans up any children in the tree.
    $node_ref->get_parent->delete_child(
        child           => $node_ref,
        no_delete_cache => 1
    );

    #  now we delete it and its descendents from the node hash
    $self->delete_from_node_hash( nodes => \%node_hash );

    #  Now we clear the caches from those deleted nodes and those remaining
    #  This circumvents circular refs from the caches.
    if ( !$args{no_delete_cache} ) {
        #  deleted nodes
        foreach my $n_ref ( values %node_hash ) {
            $n_ref->delete_cached_values;
        }
        #  remaining nodes
        $self->delete_all_cached_values;
    }

    #  return a list of the names of those deleted nodes
    return wantarray ? keys %node_hash : [ keys %node_hash ];
}

sub delete_from_node_hash {
    my $self = shift;
    my %args = @_;

    if ( $args{node} ) {
        #  $args{node} implies single deletion
        delete $self->{TREE_BY_NAME}{ $args{node} };
    }

    return if !$args{nodes};

    my @list;
    if (is_hashref($args{nodes})) {
        @list = keys %{$args{nodes}};
    }
    elsif (is_arrayref($args{nodes})) {
        @list = @{$args{nodes}};
    }
    else {
        @list = ($args{nodes});
    }
    delete @{ $self->{TREE_BY_NAME} }{@list};

    return;
}

#  add a new TreeNode to the hash, return it
sub add_node {
    my $self = shift;
    my %args = @_;
    my $node = $args{node_ref} || Biodiverse::TreeNode->new(@_);
    $self->add_to_node_hash_aa ( $node, $args{name} );

    return $node;
}

sub delete_all_cached_values {
    my $self = shift;

    #  clear each node's cache
    foreach my $n_ref ( $self->get_node_refs ) {
        $n_ref->delete_cached_values;
    }
    #  now clear our own
    $self->delete_cached_values;
    return;
}

sub splice_into_lineage {
    my ($self, %args) = @_;
    my $target   = $args{target_node};
    my $new_node = $args{new_node};
    my $no_cache_cleanup = $args{no_cache_cleanup};
    
    croak "New node must be defined and blessed\n" if !defined $new_node && blessed $new_node;
    croak "New node is not a terminal.  Splicing of full trees is not yet supported\n"
      if !$new_node->is_terminal_node;

    $self->add_node (node_ref => $new_node);
    my $new_parent = $target->splice_into_lineage (
        %args,
        no_cache_cleanup => 1,  #  we will handle it
    );
    if (!$self->exists_node(node_ref => $new_parent)) {
        $self->add_node (node_ref => $new_parent);
    }
    if (!$no_cache_cleanup) {
        $self->delete_cached_values;
        foreach my $node (values %{$self->{TREE_BY_NAME}}) {
            $node->delete_cached_values;
        }
    }
    
    return $new_parent;
}

sub add_to_node_hash {
    my ($self, %args) = @_;

    my $node_ref = $args{node_ref};
    my $name     = $node_ref->get_name;

    if ( $self->exists_node_name_aa( $name ) ) {
        Biodiverse::Tree::NodeAlreadyExists->throw(
            message => "Node $name already exists in this tree\n",
            name    => $name,
        );
    }

    $self->{TREE_BY_NAME}{$name} = $node_ref;
    #return $node_ref if defined wantarray;
}

sub add_to_node_hash_aa {
    my ($self, $node_ref, $name) = @_;

    $name //= $node_ref->get_name;

    if ( $self->exists_node_name_aa( $name ) ) {
        Biodiverse::Tree::NodeAlreadyExists->throw(
            message => "Node $name already exists in this tree\n",
            name    => $name,
        );
    }

    $self->{TREE_BY_NAME}{$name} = $node_ref;
    #return $node_ref if defined wantarray;
}

sub rename_node {
    my $self = shift;
    my %args = @_;

    my $new_name = $args{new_name}
      // croak "new_name arg not passed";
    my $node_ref = $args{node_ref};

    my $old_name;
    if (!$node_ref) {
        $old_name = $args{old_name} // $args{node_name} // $args{name}
          // croak "old_name or node_ref arg not passed\n";
        $node_ref = $self->get_node_ref_aa ($old_name);
    }
    else {
        $old_name = $node_ref->get_name;
    }

    croak "Cannot rename over an existing node ($old_name => $new_name)"
      if $self->exists_node(name => $new_name);

    $node_ref->rename (new_name => $new_name);
    $self->add_to_node_hash (node_ref => $node_ref);
    $self->delete_from_node_hash(node => $old_name);
    return;
}

#  does this node exist already?
sub exists_node {
    my $self = shift;
    my %args = @_;
    my $name = $args{name};
    if ( not defined $name ) {
        if ( defined $args{node_ref} ) {
            $name = $args{node_ref}->get_name;
        }
        else {
            croak 'neither name nor node_ref argument passed';
        }
    }
    return exists $self->{TREE_BY_NAME}{$name};
}

sub exists_node_name_aa {
    return exists $_[0]->{TREE_BY_NAME}{$_[1]};
}

#  get a single root node - assumes we only care about one if we use this approach.
#  the sort ensures we get the same one each time.
sub get_tree_ref {
    my $self = shift;
    if ( !defined $self->{TREE} ) {
        my %root_nodes = $self->get_root_nodes;
        my @keys       = sort keys %root_nodes;
        return undef if not defined $keys[0];    #  no tree ref yet
        $self->{TREE} = $root_nodes{ $keys[0] };
    }
    return $self->{TREE};
}

sub get_tree_depth {    #  traverse the tree and calculate the maximum depth
                        #  need ref to the root node
    my $self     = shift;
    my $tree_ref = $self->get_tree_ref;
    return if !defined $tree_ref;
    return $tree_ref->get_depth_below;
}

sub get_tree_length {    # need ref to the root node
    my $self     = shift;
    my $tree_ref = $self->get_tree_ref;
    return if !defined $tree_ref;
    return $tree_ref->get_length_below;
}

#  this is going to supersede get_tree_length because it is a better name
sub get_length_to_tip {
    my $self = shift;

    return $self->get_tree_length;
}

#  an even better name than get_length_to_tip given what this does
sub get_longest_path_to_tip {
    my $self = shift;

    return $self->get_tree_length;
}

#  Get the terminal elements below this node
#  If not a TreeNode reference, then return a
#  hash ref containing only this node
sub get_terminal_elements {
    my $self = shift;
    my %args = ( cache => 1, @_ );    #  cache by default

    my $node = $args{node}
      || croak "node not specified in call to get_terminal_elements\n";

    my $node_ref = $self->get_node_ref_aa ( $node );

    return $node_ref->get_terminal_elements( cache => $args{cache} )
      if defined $node_ref;

    my %hash = ( $node => $node_ref );
    return wantarray ? %hash : \%hash;
}

sub get_terminal_element_count {
    my $self = shift;
    my %args = ( cache => 1, @_ );    #  cache by default

    my $node_ref;
    if ( defined $args{node} ) {
        $node_ref = $self->get_node_ref_aa ( $args{node} );
    }
    else {
        $node_ref = $self->get_tree_ref;
    }

    #  follow logic of get_terminal_elements, which returns a hash of
    #  node if not a ref - good or bad idea?  Ever used?
    return 1 if !defined $node_ref;

    return $node_ref->get_terminal_element_count( cache => $args{cache} );
}

sub get_node_ref {
    my $self = shift;
    my %args = @_;

    my $node = $args{node}
      // croak "node not specified in call to get_node_ref\n";

    if ( !exists $self->{TREE_BY_NAME}{$node} ) {

        #say "Couldn't find $node, the nodes actually in the tree are:";
        #foreach my $k (keys $self->{TREE_BY_NAME}) {
        #    say "key: $k";
        #}
        Biodiverse::Tree::NotExistsNode->throw(
            "[Tree] $node does not exist, cannot get ref"
        );
    }

    return $self->{TREE_BY_NAME}{$node};
}

#  array args version of get_node_ref.
#  Hot path so use @_ directly to avoid bookkeeping overheads
sub get_node_ref_aa {
    croak "node not specified in call to get_node_ref_aa\n"
      if !defined $_[1];

    return $_[0]->{TREE_BY_NAME}{$_[1]}
      // Biodiverse::Tree::NotExistsNode->throw("[Tree] $_[1] does not exist, cannot get ref (aa)");
}

#  used when importing from a BDX file, as they don't keep weakened refs weak.
#  not anymore - let the destroy method handle it
sub weaken_parent_refs {
    my $self      = shift;
    my $node_list = $self->get_node_hash;
    foreach my $node_ref ( values %$node_list ) {
        $node_ref->weaken_parent_ref;
    }
}

#  pre-allocate hash buckets for really large node hashes
#  and thus gain a minor speed improvement in such cases
sub set_node_hash_key_count {
    my $self  = shift;
    my $count = shift;

    croak "Count $count is not numeric" if !looks_like_number $count;

    my $node_hash = $self->get_node_hash;

    #  has no effect if $count is negative or
    #  smaller than current key count
    keys %$node_hash = $count;

    return;
}

sub get_node_count {
    my $self     = shift;
    my $hash_ref = $self->get_node_hash;
    return scalar keys %$hash_ref;
}

sub get_node_hash {
    my $self = shift;

    #  create an empty hash if needed
    $self->{TREE_BY_NAME} //= {};

    return wantarray ? %{ $self->{TREE_BY_NAME} } : $self->{TREE_BY_NAME};
}

sub get_node_refs {
    my $self = shift;
    my @refs = values %{ $self->get_node_hash };

    return wantarray ? @refs : \@refs;
}

#  get a hash on the node lengths indexed by name
sub get_node_length_hash {
    my $self = shift;
    my %args = ( cache => 1, @_ );

    my $use_cache = $args{cache};
    if ($use_cache) {
        my $cached_hash = $self->get_cached_value('NODE_LENGTH_HASH');
        return ( wantarray ? %$cached_hash : $cached_hash ) if $cached_hash;
    }

    my %len_hash;
    my $node_hash = $self->get_node_hash;
    foreach my $node_name ( keys %$node_hash ) {
        my $node_ref = $node_hash->{$node_name};
        $len_hash{$node_name} = $node_ref->get_length;
    }

    if ($use_cache) {
        $self->set_cached_value( NODE_LENGTH_HASH => \%len_hash );
    }

    return wantarray ? %len_hash : \%len_hash;
}

sub get_zero_node_length_hash {
    my $self = shift;
    my %args = ( cache => 1, @_ );

    my $use_cache = $args{cache};
    if ($use_cache) {
        my $cached_hash = $self->get_cached_value('ZERO_NODE_LENGTH_HASH');
        return ( wantarray ? %$cached_hash : $cached_hash ) if $cached_hash;
    }

    my $node_hash = $self->get_node_length_hash;
    my %zero_len_hash = %$node_hash{grep {!$node_hash->{$_}} keys %$node_hash};

    if ($use_cache) {
        $self->set_cached_value( ZERO_NODE_LENGTH_HASH => \%zero_len_hash );
    }

    return wantarray ? %zero_len_hash : \%zero_len_hash;
}

#  get a hash of node refs indexed by their total length
sub get_node_hash_by_total_length {
    my $self = shift;

    my %by_value;
    while ( ( my $node_name, my $node_ref ) =
        each( %{ $self->get_node_hash } ) )
    {
        #  uses total_length param if exists
        my $value = $node_ref->get_length_below;
        $by_value{$value}{$node_name} = $node_ref;
    }

    return wantarray ? %by_value : \%by_value;
}

#  get a hash of node refs indexed by their depth below (same order meaning as total length)
sub get_node_hash_by_depth_below {
    my $self = shift;

    my %by_value;
    while ( ( my $node_name, my $node_ref ) =
        each( %{ $self->get_node_hash } ) )
    {
        my $depth = $node_ref->get_depth_below;
        $by_value{$depth}{$node_name} = $node_ref;
    }
    return wantarray ? %by_value : \%by_value;
}

#  get a hash of node refs indexed by their depth
sub get_node_hash_by_depth {
    my $self = shift;

    my %by_value;
    while ( ( my $node_name, my $node_ref ) =
        each( %{ $self->get_node_hash } ) )
    {
        my $depth = $node_ref->get_depth;
        $by_value{$depth}{$node_name} = $node_ref;
    }

    return wantarray ? %by_value : \%by_value;
}

#  get a hash of the node names with values as the depths
sub get_node_name_depth_hash {
    my $self = shift;
    
    if (my $cached = $self->get_cached_value ('NODE_NAME_DEPTH_HASH')) {
        return wantarray ? %$cached : $cached;
    }
    
    my $node_hash = $self->get_node_hash;
    
    my %names_and_depths
      = map {$_->[0] => $_->[2]}
        sort {$b->[2] <=> $a->[2]}
        map {[$_, $node_hash->{$_}, $node_hash->{$_}->get_depth]}
        keys %$node_hash;
    
    $self->set_cached_value (NODE_NAME_DEPTH_HASH => \%names_and_depths);
    
    return wantarray ? %names_and_depths : \%names_and_depths;
}

#  get a hash of the nodes keyed by name where values are the parent names
sub get_node_name_parent_hash {
    my $self = shift;
    
    state $cache_name = 'NODE_NAME_PARENT_HASH';
    if (my $cached = $self->get_cached_value ($cache_name)) {
        return wantarray ? %$cached : $cached;
    }
    
    my %parent_hash;
    
    foreach my $node_ref ($self->get_node_refs) {
        my $parent = $node_ref->get_parent;
        next if !defined $parent;
        $parent_hash{$node_ref->get_name} = $parent->get_name;
    }
    
    $self->set_cached_value ($cache_name => \%parent_hash);
    
    return wantarray ? %parent_hash : \%parent_hash;
}


#  get a set of stats for one of the hash lists in the tree.
#  Should be called get_list_value_stats
#  should just return the stats object
#  Should also inherit from Biodiverse::BaseStruct::get_list_value_stats?
#  It is almost identical.
sub get_list_stats {
    my $self  = shift;
    my %args  = @_;
    my $list  = $args{list} || croak "List not specified\n";
    my $index = $args{index} || croak "Index not specified\n";

    my @data;
    foreach my $node ( values %{ $self->get_node_hash } ) {
        my $list_ref = $node->get_list_ref( list => $list );
        next if !defined $list_ref;
        next if !exists $list_ref->{$index};
        next if !defined $list_ref->{$index};    #  skip undef values

        push @data, $list_ref->{$index};
    }

    my %stats_hash = (
        MAX    => undef,
        MIN    => undef,
        MEAN   => undef,
        SD     => undef,
        PCT025 => undef,
        PCT975 => undef,
        PCT05  => undef,
        PCT95  => undef,
    );

    if ( scalar @data ) {    #  don't bother if they are all undef
        my $stats = $stats_class->new;
        $stats->add_data( \@data );

        %stats_hash = (
            MAX    => $stats->max,
            MIN    => $stats->min,
            MEAN   => $stats->mean,
            SD     => $stats->standard_deviation,
            PCT025 => scalar $stats->percentile(2.5),
            PCT975 => scalar $stats->percentile(97.5),
            PCT05  => scalar $stats->percentile(5),
            PCT95  => scalar $stats->percentile(95),
        );
    }

    return wantarray ? %stats_hash : \%stats_hash;
}

#  return 1 if the tree contains a node with the specified name
sub node_is_in_tree {
    my $self = shift;
    my %args = @_;

    my $node_name = $args{node};

    #  node cannot exist if it has no name...
    croak "node name undefined\n"
      if !defined $node_name;

    my $node_hash = $self->get_node_hash;
    return exists $node_hash->{$node_name};
}

sub get_terminal_nodes {
    my $self = shift;
    
    my $cache = $self->get_cached_value ('TERMINAL_NODE_HASH');
    return wantarray ? %$cache : $cache
      if $cache;

    my %node_list;
    foreach my $node_ref ( values %{ $self->get_node_hash } ) {
        next if !$node_ref->is_terminal_node;
        $node_list{ $node_ref->get_name } = $node_ref;
    }
    $self->set_cached_value (TERMINAL_NODE_HASH => \%node_list);

    return wantarray ? %node_list : \%node_list;
}

sub get_terminal_node_refs {
    my $self = shift;
    my @node_list;

    foreach my $node_ref ( values %{ $self->get_node_hash } ) {
        next if !$node_ref->is_terminal_node;
        push @node_list, $node_ref;
    }

    return wantarray ? @node_list : \@node_list;
}

sub get_terminal_node_refs_sorted_by_name {
    my $self = shift;
    my @node_list;

    foreach my $node_ref ( values %{ $self->get_node_hash } ) {
        next if !$node_ref->is_terminal_node;
        push @node_list, $node_ref;
    }

    @node_list = natkeysort {$_->get_name} @node_list;

    return wantarray ? @node_list : \@node_list;
}

#  don't cache these results as they can change as clusters are built
sub get_root_nodes {    #  if there are several root nodes
    my $self = shift;

    my %node_list;
    my $node_hash = $self->get_node_hash;

    my @roots = grep {defined $_ && $_->is_root_node} values %$node_hash;
    my @names = map {$_->get_name} @roots;
    @node_list{@names} = @roots;
    #foreach my $node_ref ( values %$node_hash ) {
    #    next if !defined $node_ref;
    #    if ( $node_ref->is_root_node ) {
    #        $node_list{ $node_ref->get_name } = $node_ref;
    #    }
    #}

    return wantarray ? %node_list : \%node_list;
}

#  we should never have many, so we can
#  get away with array context
#  and passing through to get_root_nodes,
#  only to throw away the names
sub get_root_node_refs {
    my $self = shift;

    my @refs = values %{ $self->get_root_nodes };

    return wantarray ? @refs : \@refs;
}

sub get_root_node {
    my ($self, %args) = @_;
    
    if ($args{tree_has_one_root_node}) {
        #  We can be sure there is only one,
        #  so avoid a full search of all nodes.
        #  Pick one and climb up.
        my $node_hash = $self->get_node_hash;
        my $tester = (values %$node_hash)[0];
        while (my $parent = $tester->get_parent) {
            $tester = $parent;
        }
        return wantarray ? ($tester->get_name => $tester) : $tester;
    }

    my $root_nodes = $self->get_root_nodes;
    croak "More than one root node\n" if scalar keys %$root_nodes > 1;

    my @refs          = values %$root_nodes;
    my $root_node_ref = $refs[0];

    croak $root_node_ref->get_name . " is not a root node!\n"
      if !$root_node_ref->is_root_node;

    return wantarray ? %$root_nodes : $root_node_ref;
}

#  get all nodes that aren't internal
sub get_named_nodes {
    my $self = shift;
    my %node_list;
    my $node_hash = $self->get_node_hash;
    foreach my $node_ref ( values %$node_hash ) {
        next if $node_ref->is_internal_node;
        $node_list{ $node_ref->get_name } = $node_ref;
    }
    return wantarray ? %node_list : \%node_list;
}

#  get all the nodes that aren't terminals
sub get_branch_nodes {
    my $self = shift;
    my %node_list;
    my $node_hash = $self->get_node_hash;
    foreach my $node_ref ( values %$node_hash ) {
        next if $node_ref->is_terminal_node;
        $node_list{ $node_ref->get_name } = $node_ref;
    }
    return wantarray ? %node_list : \%node_list;
}

sub get_branch_node_refs {
    my $self = shift;
    my @node_list;
    foreach my $node_ref ( values %{ $self->get_node_hash } ) {
        next if $node_ref->is_terminal_node;
        push @node_list, $node_ref;
    }
    return wantarray ? @node_list : \@node_list;
}

#  get an internal node name that is not currently used
sub get_free_internal_name {
    my $self = shift;
    my %args = @_;
    my $skip = $args{exclude} || {};

#  iterate over the existing nodes and get the highest internal name that isn't used
#  also check the whole translate table (keys and values) to ensure no
#    overlaps with valid user defined names
    my $node_hash    = $self->get_node_hash;
    my %reverse_skip = reverse %$skip;
    my $highest = $self->get_cached_value('HIGHEST_INTERNAL_NODE_NUMBER') // -1;
    my $name;

    while (1) {
        $highest++;
        $name = $highest . '___';
        last
          if !exists $node_hash->{$name}
          && !exists $skip->{$name}
          && !exists $reverse_skip{$name};
    }

    #foreach my $name (keys %$node_hash, %$skip) {
    #    if ($name =~ /^(\d+)___$/) {
    #        my $num = $1;
    #        next if not defined $num;
    #        $highest = $num if $num > $highest;
    #    }
    #}

    #$highest ++;
    $self->set_cached_value( HIGHEST_INTERNAL_NODE_NUMBER => $highest );

    #return $highest . '___';
    return $name;
}

sub get_unique_name {
    my $self   = shift;
    my %args   = @_;
    my $prefix = $args{prefix};
    my $suffix = $args{suffix} || q{__dup};
    my $skip   = $args{exclude} || {};

    #  iterate over the existing nodes and see if we can geberate a unique name
    #  also check the whole translate table (keys and values) to ensure no
    #    overlaps with valid user defined names
    my $node_hash = $self->get_node_hash;

    my $i           = 1;
    my $pfx         = $prefix . $suffix;
    my $unique_name = $pfx . $i;

    #my $exists = $skip ? {%$node_hash, %$skip} : $node_hash;

    while ( exists $node_hash->{$unique_name} || exists $skip->{$unique_name} )
    {
        $i++;
        $unique_name = $pfx . $i;
    }

    return $unique_name;
}

###########

sub export {
    my $self = shift;
    my %args = @_;
    
    croak "[TREE] Export:  Argument 'file' not specified or null\n"
      if not defined $args{file}
      || length( $args{file} ) == 0;

    #  get our own metadata...
    my $metadata = $self->get_metadata( sub => 'export' );

    my $sub_to_use = $metadata->get_sub_name_from_format(%args);

    #  remap the format name if needed - part of the matrices kludge
    my $component_map = $metadata->get_component_map;
    if ( $component_map->{ $args{format} } ) {
        $args{format} = $component_map->{ $args{format} };
    }

    eval { $self->$sub_to_use(%args) };
    croak $EVAL_ERROR if $EVAL_ERROR;

    return;
}

sub get_metadata_export {
    my $self = shift;

    #  get the available lists
    #my @lists = $self->get_lists_for_export;

    #  need a list of export subs
    my %subs = $self->get_subs_with_prefix( prefix => 'export_' );

    #  (not anymore)
    my @formats;
    my %format_labels;    #  track sub names by format label

    #  loop through subs and get their metadata
    my %params_per_sub;
    my %component_map;
    my $sub_list_meta;

  LOOP_EXPORT_SUB:
    foreach my $sub ( sort keys %subs ) {
        my %sub_args = $self->get_args(
            sub      => $sub,
            sub_list_meta => $sub_list_meta,
        );

        my $format = $sub_args{format};

        croak "Metadata item 'format' missing\n"
          if not defined $format;

        $format_labels{$format} = $sub;

        next LOOP_EXPORT_SUB
          if $sub_args{format} eq $EMPTY_STRING;

        my $params_array = $sub_args{parameters};

        #  Need to raise the matrices args
        #  This is extremely kludgy as it assumes there is only one
        #  output format for matrices
        if (is_hashref($params_array)) {
            my @values = values %$params_array;
            my @keys   = keys %$params_array;

            $component_map{$format} = shift @keys;
            $params_array = shift @values;
        }
        
        if (!$sub_list_meta) {
            my @x = grep {$_->get_name eq 'sub_list'} @$params_array;
            if (@x) {$sub_list_meta = $x[0]}
        }

        $params_per_sub{$format} = $params_array;

        push @formats, $format;
    }

    @formats = sort @formats;
    $self->move_to_front_of_list(
        list => \@formats,
        item => 'Nexus'
    );

    my %metadata = (
        parameters     => \%params_per_sub,
        format_choices => [
            bless(
                {
                    name       => 'format',
                    label_text => 'Format to use',
                    type       => 'choice',
                    choices    => \@formats,
                    default    => 0
                },
                $parameter_metadata_class
            ),
        ],
        format_labels => \%format_labels,
        component_map => \%component_map,
    );

    return $export_metadata_class->new( \%metadata );
}

sub get_lists_for_export {
    my $self = shift;

    my @sub_list;
    #  get a list of available sub_lists (these are actually hashes)
    foreach my $list ( sort $self->get_list_names_below (no_array_lists => 1) ) {    #  get all lists
        if ( $list eq 'SPATIAL_RESULTS' ) {
            unshift @sub_list, $list;
        }
        else {
            push @sub_list, $list;
        }
    }
    unshift @sub_list, '(no list)';

    return wantarray ? @sub_list : \@sub_list;
}

sub get_metadata_export_nexus {
    my ($self, %args) = @_;

    my @parameters = (
        {
            name       => 'use_internal_names',
            label_text => 'Label internal nodes',
            tooltip    => 'Should the internal node labels be included?',
            type       => 'boolean',
            default    => 1,
        },
        {
            name       => 'no_translate_block',
            label_text => 'Do not use a translate block',
            tooltip    => 'read.nexus in the R ape package mishandles '
              . 'named internal nodes if there is a translate block',
            type    => 'boolean',
            default => 0,
        },
        $args{sub_list_meta} || $self->get_lists_export_metadata,
        {
            name       => 'export_colours',
            label_text => 'Export colours',
            tooltip    => 'Include the branch colours last used to display the tree in the GUI',
            type       => 'boolean',
            default    => 0,
        },
    );
    for (@parameters) {
        next if blessed $_;
        bless $_, $parameter_metadata_class;
    }

    my %metadata = (
        format     => 'Nexus',
        parameters => \@parameters,
    );

    return wantarray ? %metadata : \%metadata;
}

sub export_nexus {
    my $self = shift;
    my %args = @_;

    my $file = $args{file};
    say "[TREE] WRITING TO TREE TO NEXUS FILE $file";
    my $fh = $self->get_file_handle (
        file_name => $file,
        mode      => '>',
    );

    my $export_colours = $args{export_colours};
    my $sub_list_name  = $args{sub_list};
    if (($sub_list_name // '') eq '(no list)') {
        $sub_list_name  = undef;
        $args{sub_list} = undef;
    }
    my $comment_block_hash;
    my @booters_to_cleanse;
    if ($export_colours || defined $sub_list_name) {
        my %comments_block;
        my $node_refs = $self->get_node_refs;
        foreach my $node_ref (@$node_refs) {
            my $booter = $node_ref->get_bootstrap_block;
            my $sub_list;
            if (   defined $sub_list_name
                and $sub_list = $node_ref->get_list_ref_aa ($sub_list_name)
                ) {
                $booter->set_value_aa ($sub_list_name => $sub_list);
                push @booters_to_cleanse, $booter;
            }
            #my $boot_text = $booter->encode (
            #    include_colour => $export_colours,
            #);
            #$comments_block{$node_ref->get_name} = $boot_text;
        }
        #$comment_block_hash = \%comments_block;
    }
  
    print {$fh} $self->to_nexus(
        tree_name => $self->get_param('NAME'),
        %args,
        #comment_block_hash => $comment_block_hash,
    );

    $fh->close;

    #  clean up if needed
    #  should not do so if we already had such a list?
    foreach my $booter (@booters_to_cleanse) {
        $booter->delete_value_aa ($sub_list_name);
    }

    return 1;
}

sub get_metadata_export_newick {
    my $self = shift;

    my @parameters = (
            {
                name       => 'use_internal_names',
                label_text => 'Label internal nodes',
                tooltip    => 'Should the internal node labels be included?',
                type       => 'boolean',
                default    => 1,
            },
        );

    for (@parameters) {
        bless $_, $parameter_metadata_class;
    }  

    my %args = (
        format     => 'Newick',
        parameters => \@parameters,
    );

    return wantarray ? %args : \%args;
}

sub export_newick {
    my $self = shift;
    my %args = @_;

    my $file = $args{file};

    print "[TREE] WRITING TO TREE TO NEWICK FILE $file\n";

    my $fh = $self->get_file_handle (
        file_name => $file,
        mode      => '>',
    );

    print {$fh} $self->to_newick(%args) . ';';
    $fh->close;

    return 1;
}


sub get_metadata_export_tabular_tree {
    my ($self, %args) = @_;

    my @parameters = (
        $args{sub_list_meta} || $self->get_lists_export_metadata(),
        $self->get_table_export_metadata(),
        {
            name       => 'include_plot_coords',
            label_text => 'Add plot coords',
            tooltip =>
'Allows the subsequent creation of, for example, shapefile versions of the dendrogram',
            type    => 'boolean',
            default => 0,
        },
        {
            name       => 'plot_coords_scale_factor',
            label_text => 'Plot coords scale factor',
            tooltip =>
'Scales the y-axis to fit the x-axis.  Leave as 0 for default (equalises axes)',
            type    => 'float',
            default => 0,
        },
        {
            name       => 'plot_coords_left_to_right',
            label_text => 'Plot tree from left to right',
            tooltip =>
'Leave off for default (plots as per labels and cluster tabs, root node at right, tips at left)',
            type    => 'boolean',
            default => 0,
        },
        {
            name       => 'export_colours',
            label_text => 'Export colours',
            tooltip    => 'Include the branch colours last used to display the tree in the GUI',
            type       => 'boolean',
            default    => 0,
        },
    );

    for (@parameters) {
        bless $_, $parameter_metadata_class;
    }

    my %metadata = (
        format     => 'Tabular tree',
        parameters => \@parameters,
    );

    return wantarray ? %metadata : \%metadata;
}

#  generic - should be factored out
sub export_tabular_tree {
    my $self = shift;
    my %args = @_;

    my $name = $args{name} // $self->get_param('NAME');

    #  we need this to be set for the round trip
    $args{use_internal_names} //= 1;

    # show the type of what is being exported

    my $table = $self->to_table(
        symmetric          => 1,
        name               => $name,
        use_internal_names => 1,
        %args,
    );

    $self->write_table_csv( %args, data => $table );

    return 1;
}

sub get_grouped_export_metadata {
    my @params = (
        {
            name       => 'num_clusters',
            label_text => 'Number of groups',
            type       => 'integer',
            default    => 5
        },
        {
            name       => 'use_target_value',
            label_text => "Set number of groups\nusing a cutoff value",
            tooltip    => 'Overrides the "Number of groups" setting.  '
                        . 'Uses length by default.',
            type       => 'boolean',
            default    => 0,
        },
        {
            name       => 'target_value',
            label_text => 'Value for cutoff',
            tooltip    => 'Group the nodes using some threshold value.  '
                        . 'This is analogous to the grouping when using '
                        . 'the slider bar on the dendrogram plots.',
            type    => 'float',
            default => 0,
        },
        {
            name       => 'group_by_depth',
            label_text => "Group clusters by depth\n(default is by length)",
            tooltip    => 'Use depth to define the groupings.  '
                        . 'When a cutoff is used, it will be in units of node depth.',
            type       => 'boolean',
            default    => 0,
        },
    );

    return wantarray ? @params : \@params;
}

sub get_metadata_export_table_grouped {
    my ($self, %args) = @_;

    my @parameters = (
        $args{sub_list_meta} || $self->get_lists_export_metadata,
        {
            name       => 'symmetric',
            label_text => 'Force output table to be symmetric',
            type       => 'boolean',
            default    => 1,
        },
        {
            name       => 'one_value_per_line',
            label_text => 'One value per line',
            tooltip    => 'Sparse matrix format',
            type       => 'boolean',
            default    => 0,
        },
        {
            name       => 'include_node_data',
            label_text => "Include node data\n(child counts etc)",
            type       => 'boolean',
            default    => 1,
        },
        {
            name       => 'sort_array_lists',
            label_text => 'Sort array lists',
            tooltip    => 'Should any array list results be sorted before exporting? '
                        . 'Turn this off if the original order is important.',
            type       => 'boolean',
            default    => 1,
        },
        {
            name       => 'terminals_only',
            label_text => 'Export data for terminal nodes only',
            type       => 'boolean',
            default    => 1,
        },
        $self->get_grouped_export_metadata,
        $self->get_table_export_metadata,
    );

    for (@parameters) {
        bless $_, $parameter_metadata_class;
    }

    my %metadata = (
        format     => 'Table grouped',
        parameters => \@parameters,
    );

    return wantarray ? %metadata : \%metadata;
}

sub export_table_grouped {
    my $self = shift;
    my %args = @_;

    my $file = $args{file};

    print "[TREE] WRITING TO TREE TO TABLE STRUCTURE "
        . "USING TERMINAL ELEMENTS, FILE $file\n";

    my $data = $self->to_table_group_nodes(@_);

    $self->write_table(
        %args,
        file => $file,
        data => $data
    );

    return 1;
}

#  Superseded by PE_RANGELIST index.
sub get_metadata_export_range_table {
    my $self = shift;
    my %args = @_;

    my $bd = $args{basedata_ref} || $self->get_param('BASEDATA_REF');

    #  hide from GUI if no $bd
    my $format = defined $bd ? 'Range table' : $EMPTY_STRING;
    $format = $EMPTY_STRING;    # no, just hide from GUI for now

    my @parameters = $self->get_table_export_metadata();
    for (@parameters) {
        bless $_, $parameter_metadata_class;
    }

    my %metadata = (
        format     => $format,
        parameters => \@parameters,
    );

    return wantarray ? %metadata : \%metadata;
}

sub export_range_table {
    my $self = shift;
    my %args = @_;

    my $file = $args{file};

    print "[TREE] WRITING TREE RANGE TABLE, FILE $file\n";

    my $data =
      eval { $self->get_range_table( name => $self->get_param('NAME'), @_, ) };
    croak $EVAL_ERROR if $EVAL_ERROR;

    $self->write_table(
        %args,
        file => $file,
        data => $data,
    );

    return 1;
}


sub get_lists_export_metadata {
    my $self = shift;

    my @lists = $self->get_lists_for_export;

    my $default_idx = 0;
    if ( my $last_used_list = $self->get_cached_value('LAST_SELECTED_LIST') ) {
        $default_idx = first_index { $last_used_list eq $_ } @lists;
    }

    my $metadata = [
        {
            name       => 'sub_list',
            label_text => 'List to export',
            type       => 'choice',
            choices    => \@lists,
            default    => $default_idx,
        }
    ];
    for (@$metadata) {
        bless $_, $parameter_metadata_class;
    }

    return wantarray ? @$metadata : $metadata;
}

sub get_table_export_metadata {
    my $self = shift;

    my @sep_chars =
      defined $ENV{BIODIVERSE_FIELD_SEPARATORS}
      ? @$ENV{BIODIVERSE_FIELD_SEPARATORS}
      : ( ',', 'tab', ';', 'space', ':' );

    my @quote_chars = qw /" ' + $/;    #"

    my $table_metadata_defaults = [
        {
            name => 'file',
            type => 'file'
        },
        {
            name       => 'sep_char',
            label_text => 'Field separator',
            tooltip =>
              'Suggested options are comma for .csv files, tab for .txt files',
            type    => 'choice',
            choices => \@sep_chars,
            default => 0
        },
        {
            name       => 'quote_char',
            label_text => 'Quote character',
            type       => 'choice',
            choices    => \@quote_chars,
            default    => 0
        },
    ];
    for (@$table_metadata_defaults) {
        bless $_, $parameter_metadata_class;
    }

    return wantarray ? @$table_metadata_defaults : $table_metadata_defaults;
}

#  get the maximum tree node position from zero
sub get_max_total_length {
    my $self = shift;

    my @lengths =
      reverse sort numerically keys %{ $self->get_node_hash_by_total_length };
    return $lengths[0];
}

#  duplicated by get_sum_of_branch_lengths, which has a clearer name
sub get_total_tree_length { #  calculate the total length of the tree
    my $self = shift;

    #check if length is already stored in tree object
    my $length = $self->get_cached_value('TOTAL_LENGTH');
    return $length if defined $length;

    foreach my $node_ref ( $self->get_node_refs ) {
        $length += $node_ref->get_length;
    }

    #  cache the result
    if ( defined $length ) {
        $self->set_cached_value( TOTAL_LENGTH => $length );
    }

    return $length;
}

#  convert a tree object to a matrix
#  values are the total length value of the lowest parent node that contains both nodes
#  generally excludes internal nodes
sub to_matrix {
    my $self         = shift;
    my %args         = @_;
    my $class        = $args{class} || 'Biodiverse::Matrix';
    my $use_internal = $args{use_internal};
    my $progress_bar = Biodiverse::Progress->new();

    my $name = $self->get_param('NAME');

    say "[TREE] Converting tree $name to matrix";

    my $matrix = $class->new( NAME => ( $args{name} || ( $name . "_AS_MX" ) ) );

    my %nodes = $self->get_node_hash;    #  make sure we work on a copy

    if ( !$use_internal ) {              #  strip out the internal nodes
        foreach my $node_name ( keys %nodes ) {
            if ( $nodes{$node_name}->is_internal_node ) {
                delete $nodes{$node_name};
            }
        }
    }

    my $progress;
    my $to_do = scalar keys %nodes;
    foreach my $node1 ( values %nodes ) {
        my $name1 = $node1->get_name;

        $progress++;

      NODE2:
        foreach my $node2 ( values %nodes ) {
            my $name2 = $node2->get_name;
            $progress_bar->update(
                "Converting tree $name to matrix\n($progress / $to_do)",
                $progress / $to_do,
            );

            next NODE2 if $node1 eq $node2;
            next NODE2
              if $matrix->element_pair_exists(
                element1 => $name1,
                element2 => $name2,
              );

            #my $shared_ancestor = $node1->get_shared_ancestor (node => $node2);
            #my $total_length = $shared_ancestor->get_total_length;
            #
            ##  should allow user to choose whether to just get length to shared ancestor?
            #my $path_length1 = $total_length - $node1->get_total_length;
            #my $path_length2 = $total_length - $node2->get_total_length;
            #my $path_length_total = $path_length1 + $path_length2;
            #
            #$matrix->add_element (
            #    element1 => $name1,
            #    element2 => $name2,
            #    value    => $path_length_total,
            #);

            my $last_ancestor = $self->get_last_shared_ancestor_for_nodes(
                node_names => { $name1 => 1, $name2 => 1 }, );

            my %path;
            foreach my $node_name ( $name1, $name2 ) {
                my $node_ref = $self->get_node_ref_aa ( $node_name );
                my $sub_path = $node_ref->get_path_lengths_to_ancestral_node(
                    ancestral_node => $last_ancestor,
                    %args,
                );
                @path{ keys %$sub_path } = values %$sub_path;
            }
            delete $path{ $last_ancestor->get_name() };
            my $path_length = sum values %path;
            $matrix->set_value(
                element1 => $name1,
                element2 => $name2,
                value    => $path_length,
            );
        }
    }

    return $matrix;
}

#  get table of the distances, range sizes and range overlaps between each pair of nodes
#  returns a table of values as an array
sub get_range_table {
    my $self = shift;
    my %args = @_;

    #my $progress_bar = $args{progress};
    my $progress_bar = Biodiverse::Progress->new();

    my $use_internal = $args{use_internal};    #  ignores them by default

    my $name = $self->get_param('NAME');

    #  gets the ranges from the basedata
    my $bd = $args{basedata_ref} || $self->get_param('BASEDATA_REF');

    croak "Tree has no attached BaseData object, cannot generate range table\n"
      if not defined $bd;

    my %nodes = $self->get_node_hash;          #  make sure we work on a copy

    if ( !$use_internal ) {                    #  strip out the internal nodes
        while ( my ( $name1, $node1 ) = each %nodes ) {
            if ( $node1->is_internal_node ) {
                delete $nodes{$name1};
            }
        }
    }

    my @results = [
        qw /Node1
          Node2
          Length1
          Length2
          P_dist
          Range1
          Range2
          Rel_range
          Range_shared
          Rel_shared
          /
    ];

    #declare progress tracking variables
    my ( %done, $progress, $progress_percent );
    my $to_do            = scalar keys %nodes;
    my $printed_progress = 0;

    # progress feedback to text window
    print "[TREE] CREATING NODE RANGE TABLE FOR TREE: $name  ";

    foreach my $node1 ( values %nodes ) {
        my $name1   = $node1->get_name;
        my $length1 = $node1->get_total_length;

        my $range_elements1 = $bd->get_range_union(
            labels => scalar $node1->get_terminal_elements );
        my $range1 =
            $node1->is_terminal_node
          ? $bd->get_range( element => $name1 )
          : scalar @$range_elements1
          ;    #  need to allow for labels positioned higher on the tree

        # progress feedback for text window and GUI
        $progress++;
        $progress_bar->update(
            "Converting tree $name to matrix\n" . "($progress / $to_do)",
            $progress / $to_do,
        );     #"

      LOOP_NODE2:
        foreach my $node2 ( values %nodes ) {
            my $name2 = $node2->get_name;

            next LOOP_NODE2 if $done{$name1}{$name2} || $done{$name2}{$name1};

            my $length2         = $node2->get_total_length;
            my $range_elements2 = $bd->get_range_union(
                labels => scalar $node2->get_terminal_elements );
            my $range2 =
                $node1->is_terminal_node
              ? $bd->get_range( element => $name2 )
              : scalar @$range_elements2;

            my $shared_ancestor = $node1->get_shared_ancestor( node => $node2 );
            my $length_ancestor = $shared_ancestor
              ->get_length;    #  need to exclude length of ancestor itself
            my $length1_to_ancestor =
              $node1->get_length_above( target_ref => $shared_ancestor ) -
              $length_ancestor;
            my $length2_to_ancestor =
              $node2->get_length_above( target_ref => $shared_ancestor ) -
              $length_ancestor;
            my $length_sum = $length1_to_ancestor + $length2_to_ancestor;

            my ( $range_shared, $range_rel, $shared_rel );

            if ( $range1 and $range2 )
            {  # only calculate range comparisons if both nodes have a range > 0
                if ( $name1 eq $name2 )
                { # if the names are the same, the shared range is the whole range
                    $range_shared = $range1;
                    $range_rel    = 1;
                    $shared_rel   = 1;
                }
                else {
                    #calculate shared range
                    my ( %tmp1, %tmp2 );

                    #@tmp1{@$range_elements1} = @$range_elements1;
                    @tmp2{@$range_elements2} = @$range_elements2;
                    delete @tmp2{@$range_elements1};
                    $range_shared = $range2 - scalar keys %tmp2;

                    #calculate relative range
                    my $greater_range =
                        $range1 > $range2
                      ? $range1
                      : $range2;
                    my $lesser_range =
                        $range1 > $range2
                      ? $range2
                      : $range1;
                    $range_rel = $lesser_range / $greater_range;

                    #calculate relative shared range
                    $shared_rel = $range_shared / $lesser_range;
                }
            }

            push @results,
              [
                $name1,               $name2,
                $length1_to_ancestor, $length2_to_ancestor,
                $length_sum,          $range1,
                $range2,              $range_rel,
                $range_shared,        $shared_rel
              ];
        }
    }

    return wantarray ? @results : \@results;
}

sub find_list_indices_across_nodes {
    my $self = shift;
    my %args = @_;

    my @lists = $self->get_hash_lists_below;

    my $bd = $self->get_param('BASEDATA_REF');
    my $indices_object = Biodiverse::Indices->new( BASEDATA_REF => $bd );

    my %calculations_by_index = $indices_object->get_index_source_hash;

    my %index_hash;

    #  loop over the lists and find those that are generated by a calculation
    #  This ensures we get all of them if subsets are used.
    foreach my $list_name (@lists) {
        if ( exists $calculations_by_index{$list_name} ) {
            $index_hash{$list_name} = $list_name;
        }
    }

    return wantarray ? %index_hash : \%index_hash;
}

#  terminals have no descendents,
#  which unfortunately is inconsistent with how
#  get_terminal_elements works, but it is too
#  late to change now
sub get_terminal_counts_by_depth {
    my $self = shift;
    
    my $counts = $self->get_cached_value_dor_set_default_aa (
        TERMINAL_COUNTS_BY_DEPTH => {},
    );

    return wantarray ? %$counts : $counts
      if keys %$counts;   

    foreach my $node ($self->get_node_refs) {
        if ($node->is_terminal_node) {
            $counts->{$node->get_depth} //= 0;
        }
        else {
            $counts->{$node->get_depth} += $node->get_terminal_element_count;
        }
    }

    return wantarray ? %$counts : $counts;
}

#  get depths where one of the nodes has most
#  of the tree under it, and where two of its children
#  has about 50%.  Will help with targeting LCA searches
#  Sub name needs work...
sub get_most_probable_lcas {
    my $self = shift;

    my $chunky_nodes = $self->get_cached_value_dor_set_default_aa (
        MOST_PROBABLE_LCA_HASH => {},
    );
    return wantarray ? %$chunky_nodes : $chunky_nodes
      if %$chunky_nodes;

    my $n_terminals = $self->get_terminal_element_count;

    my %chunky_nodes;
    foreach my $node ($self->get_node_refs) {
        next if $node->is_terminal_node;
        my $n_terms_this_node = $node->get_terminal_element_count;
        #  does the node have a large frqction of the terminals under it?
        my $fraction_of_all_nodes = $n_terms_this_node / $n_terminals;  
        next if $fraction_of_all_nodes < 0.66;  #  hard coded...
        #  Do two of its children have large fractions?
        my $triggered
          = grep {$_->get_terminal_element_count / $n_terms_this_node > 0.25}
            $node->get_children;
        next if $triggered < 2;
        $chunky_nodes->{$node->get_name} = {
            node_ref => $node,
            fraction => $fraction_of_all_nodes,
            depth    => $node->get_depth,
        };
    }
    
    return wantarray ? %$chunky_nodes : $chunky_nodes;
}

sub get_most_probable_lca_depths {
    my $self = shift;
    
    my $depths = $self->get_cached_value_dor_set_default_aa (
        MOST_PROBABLE_LCA_DEPTHS => [],
    );
    return wantarray ? @$depths : $depths
      if @$depths;

    my $probable_nodes = $self->get_most_probable_lcas;
    my %done;

    my @order
      = reverse
        sort {$probable_nodes->{$a}{fraction} <=> $probable_nodes->{$b}{fraction}}
        keys %$probable_nodes;

    foreach my $name (@order) {
        my $depth = $probable_nodes->{$name}{depth};
        next if $done{$depth};
        push @$depths, $depth;
        $done{$depth}++;
    }
#warn "LCA depths: " . join ' ', @$depths;
    return wantarray ? @$depths : $depths;
}


#  Will return the root node if any nodes are not on the tree
sub get_last_shared_ancestor_for_nodes {
    my $self = shift;
    my %args = @_;

    my @node_names = keys %{ $args{node_names} };

    return if !scalar @node_names;

    #my $node = $self->get_root_node;
    my $first_name = shift @node_names;
    my $first_node = $self->get_node_ref_aa ( $first_name );

    return $first_node if !scalar @node_names;

    my $path_cache
      = $self->get_cached_value ('PATH_NAME_ARRAYS')
        // do {  #  only generate default val when needed (so no dor_set_default here)
            $self->set_cached_value (PATH_NAME_ARRAYS => {});
            $self->get_cached_value ('PATH_NAME_ARRAYS')
        };

    \my @ref_path = $path_cache->{$first_name} //= $first_node->get_path_to_root_node;

    #  are there some probable depths based on an analysis of the tree?
    my $most_probable_lca_depths
      =  $args{most_probable_lca_depths}
      // $self->get_most_probable_lca_depths;

    #  working from the ends of the arrays,
    #  so use negative indices
    my $common_anc_idx = -@ref_path;

  PATH:
    foreach my $node_name ( @node_names ) {

        #  Must be just the root node left, so drop out.
        #  One day we will need to check for existence across all paths,
        #  as undefined ancestors can occur if we have multiple root nodes.
        last PATH if $common_anc_idx == -1;

        \my @cmp_path
          =   $path_cache->{$node_name}
          //= $self->get_node_ref_aa ($node_name)->get_path_to_root_node;

        #  $node_ref is the root node
        if (@cmp_path == 1) {
            $common_anc_idx = -1;
            last PATH;
        }

        my $top    = -1;

        if (@$most_probable_lca_depths) {
            foreach my $depth (@$most_probable_lca_depths) {
                next if $depth > $#ref_path || $depth > $#cmp_path;
                my $iter = -($depth+1);
                if ($ref_path[$iter] eq $cmp_path[$iter]) {
                    if ($ref_path[$iter-1] ne $cmp_path[$iter-1]) {
                        $common_anc_idx = $iter;
                        last PATH;
                    }
                    else {
                        #  save some iters if we need
                        #  to use a brute-force search
                        if ($top > $iter) {$top = $iter};
                    }
                }
            }
        }
    
        #  Compare to an equivalent relative depth to avoid needless
        #  comparisons near terminals which cannot be ancestral.
        #  i.e. if the current common ancestor is at depth 3
        #  then anything deeper cannot be an ancestor.
        #  The pay-off is for larger trees.
        #  Actually, we will never hit the end of either array
        #  but the useful side effect is to detect LCA already at the root. 
        #  Tip-most entry in $path cannot be shared ancestor 
        my $bottom = max( $common_anc_idx, -(@cmp_path-1) );

        #  Climb down using a brute force loop assuming LCA
        #  is normally near the root, which it is for random
        #  pairwise assemblages used in NRI/NTI calcs.
        if (1 || $bottom > -20) {
            #  looks a bit obfuscated, but perl optimises reverse-range loop constructs
            #  and this avoids a variable increment per loop
            foreach my $iter (reverse (($bottom - 1) .. ($top - 1))) {
                if ($ref_path[$iter] ne $cmp_path[$iter]) {
                    $top = $iter + 1;
                    last;
                }
            }

            $common_anc_idx = $top;
        }
        #  binary search, disabled for now as profiling
        #  shows it is not usefully faster under NRI/NTI
        else {
            my $mid = $bottom;
          BINSEARCH:
            while ($top > $bottom) {
                #  linear search when close
                #  workaround for not getting the binary search quite right
                if (($top - $bottom) < 5) {
                    while ($top >= $bottom) {                        
                        if ($ref_path[$top-1] ne $cmp_path[$top-1]) {
                            $mid = $top;
                            last BINSEARCH;
                        }
                        $top--;
                    }
                }
                
                $mid = int (($top + $bottom) / 2);
                #  init bottom can be an LCA since we skip lowest array elements
                if ($ref_path[$mid-1] ne $cmp_path[$mid-1]) {
                    last if $ref_path[$mid] eq $cmp_path[$mid];
                    $bottom = $mid;
                }
                else {
                    $top = $mid;
                }
            }
            $common_anc_idx = $mid;
        }
    }
    
    return $ref_path[$common_anc_idx];
}

########################################################
#  Compare one tree object against another
#  Compares the similarity of the terminal elements using the Sorenson metric
#  Creates a new list in the tree object containing values based on the rand_compare
#  argument in the relevant indices
#  This is really designed for the randomisation procedure, but has more
#  general applicability.
#  As of issue #284, we optionally skip tracking the stats,
#  thus avoiding double counting since we compare the calculations per
#  node using a cloned tree
sub compare {
    my $self = shift;
    my %args = @_;

    #  make all numeric warnings fatal to catch locale/sprintf issues
    use warnings FATAL => qw { numeric };

    my $comparison = $args{comparison}
      || croak "Comparison not specified\n";

    my $track_matches    = !$args{no_track_matches};
    my $track_node_stats = !$args{no_track_node_stats};
    my $terminals_only   = $args{terminals_only};
    my $comp_precision   = $args{comp_precision} // 1e-10;

    my $result_list_pfx = $args{result_list_name};
    if ( !$track_matches ) {    #  avoid some warnings lower down
        $result_list_pfx //= q{};
    }

    croak "Comparison list name not specified\n"
      if !defined $result_list_pfx;

    my $result_data_list                  = $result_list_pfx . "_DATA";
    my $result_identical_node_length_list = $result_list_pfx . "_ID_LDIFFS";

    my $progress = Biodiverse::Progress->new();
    my $progress_text
      = sprintf "Comparing %s with %s\n",
      $self->get_param('NAME'),
      $comparison->get_param('NAME');
    $progress->update( $progress_text, 0 );

    #print "\n[TREE] " . $progress_text;

    #  set up the comparison operators if it has spatial results
    my $has_spatial_results =
      defined $self->get_list_ref( list => 'SPATIAL_RESULTS', );
    my %base_list_indices;

    if ( $track_matches && $has_spatial_results ) {

        %base_list_indices = $self->find_list_indices_across_nodes;
        $base_list_indices{SPATIAL_RESULTS} = 'SPATIAL_RESULTS';

        foreach my $list_name ( keys %base_list_indices ) {
            $base_list_indices{$list_name} =
              $result_list_pfx . '>>' . $list_name;
        }

    }

#  now we chug through each node, finding its most similar comparator node in the other tree
#  we store the similarity value as a measure of cluster reliability and
#  we then use that node to assess how goodthe spatial results are
    my $min_poss_value = 0;
    my $max_poss_value = 1;
    my %compare_nodes  = $comparison->get_node_hash;    #  make sure it's a copy
    my %done;
    my %found_perfect_match;

    my $to_do = max( $self->get_node_count, $comparison->get_node_count );
    my $i = 0;

    #my $last_update = [gettimeofday];

  BASE_NODE:
    foreach my $base_node ( $self->get_node_refs ) {
        $i++;
        $progress->update( $progress_text . "(node $i / $to_do)", $i / $to_do );

        my %base_elements  = $base_node->get_terminal_elements;
        my $base_node_name = $base_node->get_name;
        my $min_val        = $max_poss_value;
        my $most_similar_node;

        #  A small optimisation - if they have the same name then
        #  they can often have the same terminals so this will
        #  reduce the search times
        my @compare_name_list = keys %compare_nodes;
        if ( exists $compare_nodes{$base_node_name} ) {
            unshift @compare_name_list, $base_node_name;
        }

      COMP:
        foreach my $compare_node_name (@compare_name_list) {
            next if exists $found_perfect_match{$compare_node_name};
            my $sorenson = $done{$compare_node_name}{$base_node_name}
              // $done{$base_node_name}{$compare_node_name};

            if ( !defined $sorenson )
            {    #  if still not defined then it needs to be calculated
                my %comp_elements =
                  $compare_nodes{$compare_node_name}->get_terminal_elements;
                my %union_elements = ( %comp_elements, %base_elements );
                my $abc = scalar keys %union_elements;
                my $aa =
                  ( scalar keys %base_elements ) +
                  ( scalar keys %comp_elements ) -
                  $abc;
                $sorenson = 1 - ( ( 2 * $aa ) / ( $aa + $abc ) );
                $done{$compare_node_name}{$base_node_name} = $sorenson;
            }

            if ( $sorenson <= $min_val ) {
                $min_val           = $sorenson;
                $most_similar_node = $compare_nodes{$compare_node_name};
                carp $compare_node_name if !defined $most_similar_node;
                if ( $sorenson == $min_poss_value ) {

                    #  cannot be related to another node
                    if ($terminals_only) {
                        $found_perfect_match{$compare_node_name} = 1;
                    }
                    else {
                        my $len_base = $base_node->get_length;
                        #  If its length is same then we have perfect match
                        my $diff
                          = $compare_nodes{$compare_node_name}->get_length
                            - $len_base;
                        if ( abs ($diff) < $comp_precision ) {
                            $found_perfect_match{$compare_node_name}
                              = $len_base;
                        }

                        #else {say "$compare_node_name, $len_comp, $len_base"}
                    }
                    last COMP;
                }
            }
            carp "$compare_node_name $sorenson $min_val"
              if !defined $most_similar_node;
        }

        next BASE_NODE if !$track_matches;

        if ($track_node_stats) {
            $base_node->add_to_lists( $result_data_list => [$min_val] );
            my $stats = $stats_class->new;

            $stats->add_data(
                $base_node->get_list_ref( list => $result_data_list ) );
            my $prev_stat =
              $base_node->get_list_ref( list => $result_list_pfx );
            my %stats = (
                MEAN            => $stats->mean,
                SD              => $stats->standard_deviation,
                MEDIAN          => $stats->median,
                Q25             => scalar $stats->percentile(25),
                Q05             => scalar $stats->percentile(5),
                Q01             => scalar $stats->percentile(1),
                COUNT_IDENTICAL => ( $prev_stat->{COUNT_IDENTICAL} || 0 ) +
                  ( $min_val == $min_poss_value ? 1 : 0 ),
                COMPARISONS => ( $prev_stat->{COMPARISONS} || 0 ) + 1,
            );
            $stats{PCT_IDENTICAL} =
              100 * $stats{COUNT_IDENTICAL} / $stats{COMPARISONS};

            my $length_diff =
              ( $min_val == $min_poss_value )
              ? [ $base_node->get_total_length -
                  $most_similar_node->get_total_length ]
              : [];    #  empty array by default

            $base_node->add_to_lists(
                $result_identical_node_length_list => $length_diff );

            $base_node->add_to_lists( $result_list_pfx => \%stats );
        }

        if ($has_spatial_results) {
          BY_INDEX_LIST:
            while ( my ( $list_name, $result_list_name ) =
                each %base_list_indices )
            {

                my $base_ref = $base_node->get_list_ref( list => $list_name, );

                my $comp_ref =
                  $most_similar_node->get_list_ref( list => $list_name, );
                next BY_INDEX_LIST if !defined $comp_ref;

                my $results =
                  $base_node->get_list_ref( list => $result_list_name, )
                  || {};

                $self->compare_lists_by_item(
                    base_list_ref    => $base_ref,
                    comp_list_ref    => $comp_ref,
                    results_list_ref => $results,
                );

                #  add list to the base_node if it's not already there
                if (
                    !defined $base_node->get_list_ref(
                        list => $result_list_name ) )
                {
                    $base_node->add_to_lists( $result_list_name => $results );
                }
            }
        }
    }

    $self->set_last_update_time;

    return scalar keys %found_perfect_match;
}

sub convert_comparisons_to_significances {
    my $self = shift;
    my %args = @_;

    my $result_list_pfx = $args{result_list_name};
    croak qq{Argument 'result_list_name' not specified\n}
      if !defined $result_list_pfx;

    my $progress      = Biodiverse::Progress->new();
    my $progress_text = "Calculating significances";
    $progress->update( $progress_text, 0 );

    # find all the relevant lists for this target name
    my @target_list_names = grep { $_ =~ /^$result_list_pfx>>(?!\w+>>)/ }
      $self->get_hash_list_names_across_nodes;

    my $i = 0;
  BASE_NODE:
    foreach my $base_node ( $self->get_node_refs ) {

        $i++;

        #$progress->update ($progress_text . "(node $i / $to_do)", $i / $to_do);

      BY_INDEX_LIST:
        foreach my $list_name (@target_list_names) {
            my $result_list_name = $list_name =~ s/>>/>>p_rank>>/r;

            my $comp_ref = $base_node->get_list_ref( list => $list_name, );
            next BY_INDEX_LIST if !defined $comp_ref;

            #  this will autovivify it
            my $result_list_ref =
              $base_node->get_list_ref( list => $result_list_name, );
            if ( !$result_list_ref ) {
                $result_list_ref = {};
                $base_node->add_to_lists(
                    $result_list_name => $result_list_ref,
                    use_ref           => 1,
                );
            }

            #  this will result in fewer greps inside the sig rank sub
            my $base_ref_name = $list_name =~ s/.+>>//r;
            my $base_list_ref = $base_node->get_list_ref_aa( $base_ref_name );

            $self->get_sig_rank_from_comp_results(
                base_list_ref    => $base_list_ref,
                comp_list_ref    => $comp_ref,
                results_list_ref => $result_list_ref,    #  do it in-place
            );
        }
    }
}

sub convert_comparisons_to_zscores {
    my $self = shift;
    my %args = @_;

    my $result_list_pfx = $args{result_list_name};
    croak qq{Argument 'result_list_name' not specified\n}
      if !defined $result_list_pfx;

    my $progress      = Biodiverse::Progress->new();
    my $progress_text = "Calculating z-scores";
    $progress->update( $progress_text, 0 );

    # find all the relevant lists for this target name
    my @target_list_names = grep { $_ =~ /^$result_list_pfx>>(?!\w+>>)/ }
      $self->get_hash_list_names_across_nodes;

    my $i = 0;
  BASE_NODE:
    foreach my $base_node ( $self->get_node_refs ) {

        $i++;

        #$progress->update ($progress_text . "(node $i / $to_do)", $i / $to_do);

      BY_INDEX_LIST:
        foreach my $list_name (@target_list_names) {
            my $base_list_name = $list_name =~ s/^$result_list_pfx>>//r;
            my $base_ref = $base_node->get_list_ref (
                list        => $base_list_name,
                autovivify  => 0,
            );

            my $result_list_name = $list_name;
            $result_list_name =~ s/>>/>>z_scores>>/;

            my $comp_ref = $base_node->get_list_ref( list => $list_name, );
            next BY_INDEX_LIST if !defined $comp_ref;

            #  this will autovivify it
            my $result_list_ref =
              $base_node->get_list_ref( list => $result_list_name );
            if ( !$result_list_ref ) {
                $result_list_ref = {};
                $base_node->add_to_lists(
                    $result_list_name => $result_list_ref,
                    use_ref           => 1,
                );
            }

            $self->get_zscore_from_comp_results (
                comp_list_ref    => $comp_ref,
                base_list_ref    => $base_ref,
                results_list_ref => $result_list_ref,  #  do it in-place
            );
        }
    }
}

sub calculate_canape {
    my $self = shift;
    my %args = @_;

    my $result_list_pfx = $args{result_list_name};
    croak qq{Argument 'result_list_name' not specified\n}
      if !defined $result_list_pfx;

    #  check if we have the relevant calcs here
    return if !$self->check_canape_protocol_is_valid;

    my $progress      = Biodiverse::Progress->new();
    my $progress_text = "Calculating CANAPE codes";
    $progress->update( $progress_text, 0 );

    # find all the relevant lists for this target name
    my $list_name        = 'SPATIAL_RESULTS';
    my $p_rank_list_name = $result_list_pfx . '>>p_rank>>' . $list_name;
    my $result_list_name = $result_list_pfx . '>>CANAPE>>';

  NODE:
    foreach my $node ( $self->get_node_refs ) {

        my $p_rank_list_ref
          = $node->get_list_ref_aa ($p_rank_list_name);

        next NODE if !$p_rank_list_ref;

        my $base_list_ref = $node->get_list_ref_aa ($list_name);

        # this will vivify it
        my $result_list_ref =
          $node->get_list_ref_aa( $result_list_name );
        if ( !$result_list_ref ) {
            $result_list_ref = {};
            $node->add_to_lists(
                $result_list_name => $result_list_ref,
                use_ref           => 1,
            );
        }

        $self->assign_canape_codes_from_p_rank_results (
            p_rank_list_ref  => $p_rank_list_ref,
            base_list_ref    => $base_list_ref,
            results_list_ref => $result_list_ref,  #  do it in-place
        );
    }
}

sub reintegrate_after_parallel_randomisations {
    my $self = shift;
    my %args = @_;

    my $from = $args{from}
      // croak "'from' argument not defined";

    my $r = $args{randomisations_to_reintegrate}
      // croak "'randomisations_to_reintegrate' argument undefined";
    
    #  should add some sanity checks here?
    #  currently they are handled by the caller,
    #  assuming it is a Basedata reintegrate call
    
    #  messy
    my @randomisations_to_reintegrate = uniq @{$args{randomisations_to_reintegrate}};
    my $rand_list_re_text
      = '^(?:'
      . join ('|', @randomisations_to_reintegrate)
      . ')>>(?!\w+>>)';
    my $re_rand_list_names = qr /$rand_list_re_text/;

    my $node_list = $self->get_node_refs;
    my @rand_lists =
        uniq
        grep {$_ =~ $re_rand_list_names}
        ($self->get_hash_list_names_across_nodes,
         $from->get_hash_list_names_across_nodes
         );

    foreach my $list_name (@rand_lists) {
        foreach my $to_node (@$node_list) {
            my $node_name = $to_node->get_name;
            my $from_node = $from->get_node_ref_aa ($node_name);
            my $lr_to     = $to_node->get_list_ref_aa ($list_name);
            my $lr_from   = $from_node->get_list_ref_aa ($list_name);

            #  get all the keys due to ties not being tracked in all cases
            my %all_keys;
            @all_keys{keys %$lr_from, keys %$lr_to} = undef;
            my %p_keys;

            #  we need to update the C_ and Q_ keys first,
            #  then recalculate the P_ keys.
            #  Get SUMX and SUMXX as well. 
            foreach my $key (keys %all_keys) {
                if ($key =~ /^P_/) {
                    $p_keys{$key}++;
                }
                else {
                    $lr_to->{$key} += ($lr_from->{$key} // 0);
                }
            }
            foreach my $key (keys %p_keys) {
                my $index = substr $key, 1; # faster than s///;
                $lr_to->{$key} = $lr_to->{"C$index"} / $lr_to->{"Q$index"};
            }
        }
    }
    my @methods = qw /
      convert_comparisons_to_significances
      convert_comparisons_to_zscores
      calculate_canape
    /;
    foreach my $rand_name (@randomisations_to_reintegrate) {
        foreach my $method (@methods) {
            $self->$method (result_list_name => $rand_name);
        }
    }

    foreach my $to_node (@$node_list) {
        my $from_node = $from->get_node_ref_aa ($to_node->get_name);

      RAND_NAME:
        foreach my $rand_name (@randomisations_to_reintegrate) {
            #  need to handle the data lists
            my $data_list_name = $rand_name . '_DATA';
            my $data = $from_node->get_list_ref (
                list => $data_list_name,
                autovivify => 0,
            );

            #  we don't generate these by default now
            next RAND_NAME if !$data;

            $to_node->add_to_lists ($data_list_name => $data);

            my $stats = $stats_class->new;

            my $stats_list_name = $rand_name;
            my $to_stats_prev   = $to_node->get_list_ref_aa ($stats_list_name);
            my $from_stats_prev = $from_node->get_list_ref_aa ($stats_list_name);

            $stats->add_data ($to_node->get_list_ref_aa ($data_list_name));
            my %stats_hash = (
                MEAN   => $stats->mean,
                SD     => $stats->standard_deviation,
                MEDIAN => $stats->median,
                Q25    => scalar $stats->percentile (25),
                Q05    => scalar $stats->percentile (5),
                Q01    => scalar $stats->percentile (1),
                COUNT_IDENTICAL
                       => (($to_stats_prev->{COUNT_IDENTICAL}   // 0)
                         + ($from_stats_prev->{COUNT_IDENTICAL} // 0)),
                COMPARISONS
                       => (($to_stats_prev->{COMPARISONS}   // 0)
                         + ($from_stats_prev->{COMPARISONS} // 0)),
            );
            $stats_hash{PCT_IDENTICAL}
              = 100 * $stats_hash{COUNT_IDENTICAL} / $stats_hash{COMPARISONS};

            #  use_ref to override existing
            $to_node->add_to_lists ($stats_list_name => \%stats_hash, use_ref => 1);  
    
            my $list_name = $rand_name . '_ID_LDIFFS';
            my $from_id_ldiffs = $from_node->get_list_ref (list => $list_name);
            $to_node->add_to_lists (
                $list_name => $from_id_ldiffs,
            );
        }
    }

    return;
}


sub get_hash_list_names_across_nodes {
    my $self = shift;

    my %list_names;
    foreach my $node ( $self->get_node_refs ) {
        my $lists = $node->get_hash_lists;
        @list_names{@$lists} = ();
    }

    my @names = sort keys %list_names;

    return wantarray ? @names : \@names;
}

sub trees_are_same {
    my $self = shift;
    my %args = @_;

    my $exact_match_count = $self->compare( %args, no_track_matches => 1 );

    my $comparison = $args{comparison}
      || croak "Comparison not specified\n";

    my $node_count_self = $self->get_node_count;
    my $node_count_comp = $comparison->get_node_count;
    my $trees_match     = $node_count_self == $node_count_comp
      && $exact_match_count == $node_count_self;

    return $trees_match;
}

#  does this tree contain a second tree as a sub-tree
sub contains_tree {
    my $self = shift;
    my %args = @_;

    my $exact_match_count = $self->compare( %args, no_track_matches => 1 );

    my $comparison = $args{comparison}
      || croak "Comparison not specified\n";

    my $node_count_comp = $comparison->get_node_count;
    if ( $args{ignore_root} ) {
        $node_count_comp--;
    }
    my $correction += $args{correction} // 0;
    $node_count_comp += $correction;

    my $contains = $exact_match_count == $node_count_comp;

    return $contains;
}

#  trim a tree to remove nodes from a set of names, or those not in a set of names
sub trim {
    my $self = shift;
    my %args = @_;

    say '[TREE] Trimming tree';

    #  delete internals by default
    my $delete_internals = $args{delete_internals} // 1;
    
    my $trim_to_lca = $args{trim_to_lca};

    my %tree_node_hash = $self->get_node_hash;

    #  Get keep and trim lists and convert to hashes as needs dictate
    #  those to keep
    my $keep = $args{keep} ? $self->array_to_hash_keys( list => $args{keep} ) : {};
    my $trim = $args{trim};    #  those to delete

 #  If the keep list is defined, and the trim list is not defined,
 #    then we work with all named nodes that don't have children we want to keep
    if ( !defined $args{trim} && defined $args{keep} ) {

        my $k          = 0;
        my $k_to_do    = scalar keys %tree_node_hash;
        my $k_progress = Biodiverse::Progress->new( text => 'Tree trimming keepers' );

      NAME:
        foreach my $name ( keys %tree_node_hash ) {
            $k++;

            next NAME if exists $keep->{$name};

            my $node = $tree_node_hash{$name};

            next NAME if $node->is_internal_node;
            #  never delete the root node
            next NAME if $node->is_root_node;

            $k_progress->update(
                "Checking keeper nodes ($k / $k_to_do)",
                $k / $k_to_do,
            );
            
            my $delete_flag = 1;
            
            if (!$node->is_terminal_node) {
                #  returns a copy
                my $children = $node->get_names_of_all_descendants;    
                my $child_count = scalar keys %$children;

                delete @$children{ keys %$keep };
                if ($child_count != scalar keys %$children) {
                    #  some descendants in the keep list,
                    #  so we keep this one
                    $delete_flag = 0;
                }
            }

            #  If none of the descendants are in the keep list then
            #  we can trim this node.
            #  Otherwise add this node and all of its ancestors
            #  to the keep list.
            if ( $delete_flag ) {
                $trim->{$name} = $node;
            }
            else {
                my $ancestors = $node->get_path_to_root_node;
                foreach my $ancestor (@$ancestors) {
                    next if $ancestor->is_internal_node;
                    $keep->{ $ancestor->get_name }++;
                }
            }
        }
    }

    my %trim_hash = $trim ? $self->array_to_hash_keys( list => $trim ) : ();  #  makes a copy

    #  we only want to consider those not being explicitly kept (included)
    my %candidate_node_hash = %tree_node_hash;
    delete @candidate_node_hash{ keys %$keep };

    my %deleted_h;
    my $ii        = 0;
    my $to_do    = scalar keys %candidate_node_hash;
    my $progress = Biodiverse::Progress->new( text => 'Deletions' );

  DELETION:
    foreach my $name ( keys %candidate_node_hash ) {
        $ii++;

        #  we might have deleted a named parent,
        #  so this node no longer exists in the tree
        next DELETION if $deleted_h{$name} || !exists $trim_hash{$name};

        $progress->update( "Checking nodes ($ii / $to_do)", $ii / $to_do, );

        #  delete if it is in the list to exclude
        my @deleted_nodes =
          $self->delete_node( node => $name, no_delete_cache => 1 );
        @deleted_h{@deleted_nodes} = (1) x scalar @deleted_nodes;
    }

    $progress->close_off;
    my $deleted_count = scalar keys %deleted_h;
    say "[TREE] Deleted $deleted_count nodes ", join ' ', sort keys %deleted_h;

    #  delete any internal nodes with no named descendents
    my $deleted_internal_count = 0;
    if ( $delete_internals and scalar keys %deleted_h ) {
        say '[TREE] Cleaning up internal nodes';

        my %node_hash = $self->get_node_hash;
        $to_do = scalar keys %node_hash;
        my %deleted_hash;
        my $j;

      NODE:
        foreach my $name ( keys %node_hash ) {
            $j++;

            my $node = $node_hash{$name};
            next NODE if $deleted_hash{$node};       #  already deleted
            next NODE if !$node->is_internal_node;
            next NODE if $node->is_root_node;

            $progress->update(
                  "Cleaning dangling internal nodes\n"
                . "($j / $to_do)",
                $j / $to_do,
            );

            #  need to ignore any cached descendants
            #  (and we clean the cache lower down)
            my $children = $node->get_all_descendants( cache => 0 );
            my $have_named_descendant
              = any {!$_->is_internal_node} values %$children;
            next NODE if $have_named_descendant;

            #  might have already been deleted, so wrap in an eval
            my @deleted_names = eval {
                $self->delete_node( node => $name, no_delete_cache => 1 )
            };
            @deleted_hash{@deleted_names} = (1) x @deleted_names;
        }
        $progress->close_off;

        $deleted_internal_count = scalar keys %deleted_hash;
        say "[TREE] Deleted $deleted_internal_count internal nodes"
           . "with no named descendents";
    }
    
    if ($trim_to_lca) {
        $self->trim_to_last_common_ancestor;
    }

    #  now some cleanup
    if ( $deleted_internal_count || $deleted_count ) {
        #  need to clear this up in old trees
        $self->delete_param('TOTAL_LENGTH');

        #  This avoids circular refs in the ones that were deleted
        foreach my $node ( values %tree_node_hash ) {
            $node->delete_cached_values;
        }
        #  and clear the remaining node caches and ourself
        $self->delete_all_cached_values;
    }
    $keep = undef;    #  was leaking - not sure it matters, though

    say '[TREE] Trimming completed';

    $progress = undef;

    return $self;
}

sub trim_to_last_common_ancestor {
    my $self = shift;

    #  Remove root nodes until they have zero or multiple children.
    #  The zeroes are kept to avoid empty trees.
    my $root = $self->get_root_node;
    my @deleters;
    while (my $children = $root->get_children) {
        last if scalar @$children != 1;
        push @deleters, $root;
        my $name = $root->get_name;
        $root = $children->[0];
        $root->delete_parent;
        $self->delete_from_node_hash (node => $name);
    }
    $root->set_length (length => 0);
    #  total_length_gui _y
    
    #  reset the tree node 
    $self->{TREE} = $root;
    $self->delete_all_cached_values;
    
    my $check = $self->get_root_node;


    return;
}


#  merge any single-child nodes with their children
sub merge_knuckle_nodes {
    my $self = shift;

    #  we start from the deepest nodes and work up
    my %depth_cache;
    my @node_refs
      = sort {($depth_cache{$b} //= $b->get_depth) <=> ($depth_cache{$a} //= $a->get_depth)}
        grep {$_->get_child_count == 1}
        $self->get_node_refs;

    my %deleted;
    foreach my $node_ref (@node_refs) {
        my $node_name = $node_ref->get_name;
        next if $deleted{$node_name};  #  skip ones we already deleted
        my $children = $node_ref->get_children;
        next if @$children != 1;  # check again as we might have added a child to this node in a previous iteration
        my $child = $children->[0];

        #say "Merging parent $node_name with child " . $child->get_name;
        #  we retain tip node, otherwise named node nearer the tip, otherwise the parent
        if ($child->is_terminal_node || !$child->is_internal_node) {
            $child->set_length_aa ($node_ref->get_length + $child->get_length);
            $node_ref->delete_child (child => $child, no_delete_cache => 1);  # we clear cache later to avoid quadratic behaviour
            $child->delete_parent;  #  avoid some cache clearing when reparented
            my $grandparent = $node_ref->get_parent;
            $grandparent->delete_child (child => $node_ref, no_delete_cache => 1);
            $grandparent->add_children (children => [$child], is_treenodes => 1, are_orphans => 1);
            $child->set_parent_aa ($grandparent);
            $self->delete_from_node_hash (node => $node_name);
            $deleted{$node_name}++;
        }
        else {
            $node_ref->set_length_aa ($node_ref->get_length + $child->get_length);
            $node_ref->delete_child (child => $child, no_delete_cache => 1);
            $child->delete_parent;  #  avoid some cache clearing when reparented
            $node_ref->add_children (children => [$child->get_children], is_treenodes => 1, are_orphans => 1);
            $self->delete_from_node_hash (node => $child->get_name);
            $deleted{$child->get_name}++;
        }

    }
    
    if (keys %deleted) {
        $self->delete_all_cached_values;
        
        #  brute force
        foreach my $node ($self->get_node_refs) {
            $node->set_depth_aa (undef);
        }
    }

    return scalar keys %deleted;
}

sub is_ultrametric {
    my $self = shift;
    
    my $is_ultrametric = $self->get_cached_value ('TREE_IS_ULTRAMETRIC');
    return $is_ultrametric if defined $is_ultrametric;
    
    my $node_refs = $self->get_terminal_node_refs;
    my $path1 = $node_refs->[0]->get_path_length_array_to_root_node_aa;
    my $len1 = sum @$path1;
    foreach my $terminal (@$node_refs) {
        my $path_to_root = $terminal->get_path_length_array_to_root_node_aa;
        my $len = sum @$path_to_root;
        if (abs ($len - $len1) > 1e-03) {  #  same as phylomeasures
            $self->set_cached_value (TREE_IS_ULTRAMETRIC => 0);
            return 0;
        }
    }
    
    $self->set_cached_value (TREE_IS_ULTRAMETRIC => 1);
    return 1;    
}

#  wrapper method so we can have a different name
sub get_sum_of_branch_lengths {
    my $self = shift;
    
    return $self->get_sum_of_branch_lengths_below;
}


sub numerically { $a <=> $b }

sub AUTOLOAD {
    my $self = shift;
    my $type = ref($self) || $self;

    #or croak "$self is not an object\n";

    my $method = $AUTOLOAD;
    $method =~ s/.*://;    # strip fully-qualified portion

    #  seem to be getting destroy issues - let the system take care of it.
    #    return if $method eq 'DESTROY';

    my $root_node = $self->get_tree_ref;

    croak 'No root node' if !$root_node;

    if ( defined $root_node and $root_node->can($method) ) {

        #print "[TREE] Using AUTOLOADER method $method\n";
        #  could check eval errors, but would need to
        #  handle list context in the caller
        return $root_node->$method(@_);
    }
    else {
        Biodiverse::NoMethod->throw(
            method  => $method,
            message => "$self cannot call method $method"
        );

      #croak "[$type (TREE)] No root node and/or cannot access method $method, "
      #    . "tried AUTOLOADER and failed\n";
    }

    return;
}

#  collapse tree to a polytomy a set distance above the tips
#  assumes ultrametric tree
# the only args are:
#   cutoff_absolute - the depth from the tips of the tree at which to cut in units of branch length
#   or cutoff_relative - the depth from the tips of the tree at which to cut as a proportion
#   of the total tree depth.
#   if both parameters are given, cutoff_relative overrides cutoff_absolute

sub collapse_tree {
    my $self = shift;    # expects a Tree object
    my %args = @_;

    my $cutoff = $args{cutoff_absolute};
    my $verbose = $args{verbose} // 1;

    my $total_tree_length = $self->get_tree_length;

    if ( defined $args{cutoff_relative} ) {
        my $cutoff_relative = $args{cutoff_relative};
        croak 'cutoff_relative argument must be between 0 and 1'
          if $cutoff_relative < 0 || $cutoff_relative > 1;

        $cutoff = $cutoff_relative * $total_tree_length;
    }

    my ( $zero_count, $shorter_count );

    my %node_hash = $self->get_node_hash;

    if ($verbose) {
        say "[TREE] Total length: $total_tree_length";
        say '[TREE] Node count: ' . ( scalar keys %node_hash );
    }

    my $node;

    my %new_node_lengths;

    #  first pass - calculate the new lengths
  NODE_NAME:
    foreach my $name ( sort keys %node_hash ) {
        $node = $node_hash{$name};

        #my $new_branch_length;

        my $node_length   = $node->get_length;
        my $length_to_tip = $node->get_length_below; #  includes length of $node
        my $upper_bound   = $length_to_tip;
        my $lower_bound = $length_to_tip - $node_length;

        my $type;

        # whole branch is inside the limit - no change
        next NODE_NAME if $upper_bound < $cutoff;

        # whole of branch is outside limit - set branch length to 0
        if ( $lower_bound >= $cutoff ) {
            $new_node_lengths{$name} = 0;
            $zero_count++;
            $type = 1;
        }

        # part of branch is outside limit - shorten branch
        else {
            $new_node_lengths{$name} = $cutoff - $lower_bound;
            $shorter_count++;
            $type = 2;
        }
    }

    #  second pass - apply the new lengths
    foreach my $name ( keys %new_node_lengths ) {
        $node = $node_hash{$name};

        my $new_length;

        if ( $new_node_lengths{$name} == 0 ) {
            $new_length =
              $node->is_terminal_node ? ( $total_tree_length / 10000 ) : 0;
        }
        else {
            $new_length = $new_node_lengths{$name};
        }

        $node->set_length( length => $new_length );

        if ($verbose) {
            say "$name: new length is $new_length";
        }
    }

    $self->delete_all_cached_values;

    #  reset all the total length values
    $self->reset_total_length;
    $self->get_total_tree_length;

    my @now_empty = $self->flatten_tree;

    #  now we clean up all the empty nodes in the other indexes
    if ($verbose) {
        say "[TREE] Deleting " . scalar @now_empty . ' empty nodes';
    }

    #foreach my $now_empty (@now_empty) {
    $self->delete_from_node_hash( nodes => \@now_empty ) if scalar @now_empty;

    #  rerun the resets - prob overkill
    $self->delete_all_cached_values;
    $self->reset_total_length;
    $self->get_total_tree_length;

    if ($verbose) {
        say '[TREE] Total length: ' . $self->get_tree_length;
        say '[TREE] Node count: ' . $self->get_node_count;
    }

    return $self;
}

sub reset_total_length {
    my $self = shift;

    #  older versions had this as a param
    $self->delete_param('TOTAL_LENGTH');
    $self->delete_cached_value('TOTAL_LENGTH');

    #  avoid recursive recursion and its quadratic nastiness
    #$self->reset_total_length_below;
    foreach my $node ( $self->get_node_refs ) {
        $node->reset_total_length;
    }

    return;
}

#  collapse all nodes below a cutoff so they form a set of polytomies
sub collapse_tree_below {
    my $self = shift;
    my %args = @_;

    my $target_hash = $self->group_nodes_below(%args);

    foreach my $node ( values %$target_hash ) {
        my %terminals = $node->get_terminal_node_refs;
        my @children  = $node->get_children;
      CHILD_NODE:
        foreach my $desc_node (@children) {
            next CHILD_NODE if $desc_node->is_terminal_node;
            eval { $self->delete_node( node => $desc_node->get_name ); };
        }

        #  still need to ensure they are in the node hash
        $node->add_children( children => [ sort values %terminals ] );

        #print "";
    }

    return 1;
}

#  root an unrooted tree using a zero length node.
sub root_unrooted_tree {
    my $self = shift;

    my @root_nodes = $self->get_root_node_refs;

    return if scalar @root_nodes <= 1;

    my $name = $self->get_free_internal_name;
    my $new_root_node = $self->add_node( length => 0, name => $name );

    $new_root_node->add_children( children => \@root_nodes );

    @root_nodes = $self->get_root_node_refs;
    croak "failure\n" if scalar @root_nodes > 1;

    return;
}

sub shuffle_no_change {
    my $self = shift;
    return $self;
}

#  users should make a clone before doing this...
sub shuffle_terminal_names {
    my $self = shift;
    my %args = @_;

    my $target_node = $args{target_node} // $self->get_root_node;

    my $node_hash = $self->get_node_hash;
    my %reordered = $target_node->shuffle_terminal_names(%args);

    #  place holder for nodes that will change
    my %tmp;
    while ( my ( $old, $new ) = each %reordered ) {
        $tmp{$new} = $node_hash->{$old};
    }

    #  and now we override the old with the new
    @{$node_hash}{ keys %tmp } = values %tmp;

    $self->delete_all_cached_values;

    return if !defined wantarray;
    return wantarray ? %reordered : \%reordered;
}

sub clone_tree_with_equalised_branch_lengths {
    my $self = shift;
    my %args = @_;

    my $name = $args{name} // ( $self->get_param('NAME') . ' EQ' );

    my $non_zero_len = $args{node_length}
     // ($self->get_total_tree_length / ( $self->get_nonzero_length_count || 1 ));

    \my %orig_node_length_hash = $self->get_node_length_hash;

    my $new_tree = $self->clone_without_caches;
    \my %new_node_hash = $new_tree->get_node_hash;

    foreach my $name ( keys %new_node_hash ) {
        my $node = $new_node_hash{$name};
        $node->set_length_aa ( $orig_node_length_hash{$name} ? $non_zero_len : 0 );
    }
    $new_tree->rename( new_name => $name );

    return $new_tree;
}

sub clone_without_caches {
    my $self = shift;
    
    #  maybe should generate a new version but blessing and parenting might take longer
    my %saved_node_caches;
    my %params = $self->get_params_hash;

    my $new_tree = do {
        #  we have to delete the new tree's caches so avoid cloning them in the first place
        delete local $self->{_cache};
        delete local $self->{PARAMS} or say STDERR 'woap?';
        #  seem not to be able to use delete local on compound structure
        #  or maybe it is the foreach loop even though postfix
        $saved_node_caches{$_} = delete $self->{TREE_BY_NAME}{$_}{_cache}
          foreach keys %{$self->{TREE_BY_NAME}};
        $self->clone;
    };

    #  reinstate the caches and other settings on the original tree
    #  could be done as a defer block with a more recent perl
    $self->{TREE_BY_NAME}{$_}{_cache} = $saved_node_caches{$_}
      foreach keys %{$self->{TREE_BY_NAME}};

    #  assign the basic params
    foreach my $param (qw /OUTSUFFIX OUTSUFFIX_YAML/) {
        $new_tree->set_param($param => $params{$param});
    }

    #  reset all the total length values
    $new_tree->reset_total_length;

    foreach my $node ( $new_tree->get_node_refs ) {
        my $sub_list_ref = $node->get_list_ref_aa ( 'NODE_VALUES' );
        delete $sub_list_ref->{_y};    #  the GUI adds these - should fix there
        delete $sub_list_ref->{total_length_gui};
    }
      
    return $new_tree;
}


sub clone_tree_with_rescaled_branch_lengths {
    my $self = shift;
    my %args = @_;

    my $name = $args{name} // ( $self->get_param('NAME') . ' RS' );

    my $new_length = $args{new_length} || 1;

    my $scale_factor
      = $args{scale_factor}
      // $new_length / ( $self->get_longest_path_length_to_terminals || 1 );

    my $new_tree = $self->clone_without_caches;

    foreach my $node ( $new_tree->get_node_refs ) {
        $node->set_length_aa ( $node->get_length * $scale_factor );
    }
    $new_tree->rename( new_name => $name );

    return $new_tree;
}

#  Algorithm from Tsirogiannis et al. (2012).
#  https://doi.org/10.1007/978-3-642-33122-0_3
sub get_nri_expected_mean {
    my ($self, %args) = @_;

    state $cache_key = 'EXACT_MPD_EXACT_EXPECTED_MEAN';

    my $expected = $self->get_cached_value ($cache_key);
    
    return $expected if $expected;
    
    my @nodes = $self->get_node_refs;
    my $s = $self->get_terminal_element_count;
    
    my $sum = 0;
    foreach my $node (@nodes) {
        my $tip_count = $node->get_terminal_element_count;
        $sum += $node->get_length * $tip_count * ($s - $tip_count);
    }
    $expected = $sum * 2 / ($s * ($s - 1));
    
    $self->set_cached_value ($cache_key => $expected);
    
    return $expected;
}


#  Algorithm from Tsirogiannis et al. (2012).
#  https://doi.org/10.1007/978-3-642-33122-0_3
sub get_nri_expected_sd {
    my $self = shift;
    my %args = @_;
    my $sample_count = $args{sample_count};

    state $cache_name = 'NRI_EXPECTED_SD_HASH';

    my $cached_data = $self->get_cached_value ($cache_name);
    
    if (!$cached_data) {
        $cached_data = {};
        $self->set_cached_value ($cache_name => $cached_data);
    }

    my $expected = $cached_data->{expected} //= {};

    return $expected->{$sample_count}
      if defined $expected->{$sample_count};

    return $expected->{$sample_count} = undef
      if $sample_count == 1;

    my $s  = $self->get_terminal_element_count;

    return $expected->{$sample_count} = 0
      if $sample_count == $s;

    croak "Cannot estimate MPD SD for $sample_count labels - "
        . "tree has only $s terminals"
      if $sample_count > $s;

    my $sum_tcuu = $cached_data->{sum_tcuu};
    my $sum_tce  = $cached_data->{sum_tce};
    my $TCE      = $cached_data->{TCE_HASH} //= {};

    if (!keys %$TCE) {
        #  need to account for top node below root node
        #  i.e. where root node has single children
        my %skippers;
        my $root = $self->get_root_node;
        while ($root->get_child_count == 1) {
            $skippers{$root->get_name}++;
            my $children = $root->get_children;
            $root = $children->[0];
        }

        foreach my $node ($self->get_node_refs) {
            my $name = $node->get_name;
            next if $skippers{$name};
            $TCE->{$name} = $node->get_nri_tce_score;
            $sum_tce += $TCE->{$name} * $node->get_length;
            if ($node->is_terminal_node) {
                $sum_tcuu += $TCE->{$name} ** 2;
            }
        }
        $cached_data->{sum_tcuu} = $sum_tcuu;
        $cached_data->{sum_tce}  = $sum_tce;
    }

    my $r  = $sample_count;  #  for brevity

    my $c1
      = 4 * ($r - 2) * ($r - 3)
      / ($r * ($r - 1) * $s * ($s - 1) * ($s - 2) * ($s - 3));
    my $c2
      = 4 * ($r - 2)
      / ($r * ($r - 1) * $s * ($s - 1) * ($s - 2));
    my $c3
      = 4
      / ($r * ($r - 1) * $s * ($s - 1));

    my $c21  = $c2 - $c1;
    my $c123 = $c1 - 2 * $c2 + $c3;

    my $expected_mean = $self->get_nri_expected_mean;
    my $TC = $expected_mean * ($s * ($s - 1)) / 2;

#  from PhyloMeasures code:    
#  L489-492 of Mean_pairwise_distance_impl.h
#  term 1 is square of total path costs
#  term 2 is sum of all leaf costs,
#     which is sum of squared leaf edge path costs
#     (L97 of Mean_pairwise_distance_base_impl.h)
#  term 3 is sum_all_edges_costs
#     see L25 of Mean_pairwise_distance_impl.h
#  term 4 is square of expected value
    my $variance
      = $c1   * $TC ** 2
      + $c21  * $sum_tcuu
      + $c123 * $sum_tce
      - $expected_mean ** 2;

    $expected->{$sample_count} = eval {sqrt $variance} // 0;

    return $expected->{$sample_count};
}

sub get_nti_expected_mean {
    my $self = shift;
    my %args = @_;
    
    croak "Cannot calculate exact expected mean for non-ultrametric tree"
      if !$self->is_ultrametric;

    my $r = $args{sample_count} // croak "Argument sample_count not defined";
    
    my $cache
      = $self->get_cached_value_dor_set_default_aa (
        NTI_EXPECTED_MEAN => {}
    );

    return $cache->{$r}
      if defined $cache->{$r};

    my $s = $self->get_terminal_element_count;
    my $cb_bnok_one_arg = $self->get_bnok_ratio_callback_one_val(r => $r, s => $s);
    my $cb_bnok_two_arg = $self->get_bnok_ratio_callback_two_val(r => $r, s => $s);

    \my %tip_count_cache
      = $self->get_cached_value_dor_set_default_aa (NODE_TIP_COUNT_CACHE => {});

    \my %len_cache
      = $self->get_cached_value_dor_set_default_aa (NODE_LENGTH_CACHE => {});

    my $sum;
    my $node_hash = $self->get_node_hash;
    foreach my $name (keys %$node_hash) {
        my $node = $node_hash->{$name};
        my $se
          = $tip_count_cache{$name}
            //= $node->get_terminal_element_count;
        $sum += ($len_cache{$name} //= $node->get_length)
              * $se
              * $cb_bnok_one_arg->($se);
    }
    
    my $expected = (2 / $r) * $sum;
    
    $cache->{$r} = $expected;

    return $expected;
}

sub get_nti_expected_sd {
    my $self = shift;
    my %args = @_;
    
    croak "Cannot calculate exact expected sd for non-ultrametric tree"
      if !$self->is_ultrametric;

    my $r = $args{sample_count} // croak "Argument sample_count not defined";
    
    my $cache
      = $self->get_cached_value_dor_set_default_aa (
        NTI_EXPECTED_SD => {}
    );

    return $cache->{$r}
      if defined $cache->{$r};
      
    my $s = $self->get_terminal_element_count;
    return $cache->{$s} = 0
      if $r == $s;
    
    my $exp_mean = $self->get_nti_expected_mean (sample_count => $r);

    my $cb_bnok_one_arg
      = $self->get_bnok_ratio_callback_one_val (s => $s, r => $r);
    my $cb_bnok_two_arg
      = $self->get_bnok_ratio_callback_two_val (s => $s, r => $r);

    \my %ancestor_cache  = $self->get_cached_value_dor_set_default_aa (NODE_ANCESTOR_LENGTH_CACHE => {});
    \my %len_cache       = $self->get_cached_value_dor_set_default_aa (NODE_LENGTH_CACHE => {});
    \my %tip_count_cache = $self->get_cached_value_dor_set_default_aa (NODE_TIP_COUNT_CACHE => {});
    \my %sum_pr_cache    = $self->get_cached_value_dor_set_default_aa (NODE_SUM_OF_PRODUCTS => {});
    my %name_cache;  #  indexed by node ref, so cannot be stored on the tree

    \my @node_refs = $self->get_cached_value_dor_set_default_aa ('NTI_NODE_REFS' => []);
    if (!@node_refs) {
        #  remove root from the array
        #  faster than a grep
        my $node_hash = $self->get_node_hash;
        delete local $node_hash->{$self->get_root_node->get_name};
        @node_refs
          = keysort {$_->get_name}
            values %$node_hash;
        $self->set_cached_value(NTI_NODE_REF_ARRAY => \@node_refs);
    };

    \my %by_se = $self->get_cached_value_dor_set_default_aa (NODE_NTI_LEN_CACHE => {});
    my @by_se_keys;
    if (!keys %by_se) {
        foreach my $node (@node_refs) {
            my $te = $node->get_terminal_element_count;
            $by_se{$te} += $node->get_length * $te;
        }
        @by_se_keys = sort {$a <=> $b} keys %by_se;
        $self->set_cached_value (NODE_NTI_LEN_CACHE_KEYS_SORTED => \@by_se_keys);
    }
    \@by_se_keys = $self->get_cached_value ('NODE_NTI_LEN_CACHE_KEYS_SORTED');
 
    #  names from PhyloMeasures
    my ($sum_subtree,    $sum_subtract,
        $sum_self,       $sum_self_third_case,
        $sum_third_case,
        $sum_same_class_third_case);

    \my @nodes_by_depth
      = $self->get_cached_value_dor_set_default_aa (
            NTI_NODES_SORTED_BY_DEPTH => []
        );
    if (!@nodes_by_depth) {
      @nodes_by_depth = rnkeysort {$_->get_depth} @node_refs;
      $self->set_cached_value (NTI_NODES_SORTED_BY_DEPTH => \@nodes_by_depth);
    }

    foreach my $node (@nodes_by_depth) {
        my $name = $name_cache{$node} //= $node->get_name;
        my $length
          = $len_cache{$name}
            //= $node->get_length;
        my $se
          = $tip_count_cache{$name}
            //= $node->get_terminal_element_count;

        #  many var names from PhyloMeasures
        my $mhyperg  = $cb_bnok_one_arg->($se);
        my $mhyperg2 = $cb_bnok_two_arg->($se, $se);

        $sum_pr_cache{$name} = $length * $se;
        foreach my $child ($node->get_children) {
            my $sum_pr
              = $sum_pr_cache{$name_cache{$child} //= $child->get_name};
            $sum_subtree += $length * $sum_pr * $mhyperg;
            $sum_pr_cache{$name} += $sum_pr;

            my $sl_len_hash = $child->_get_len_sum_by_tip_count_hash;
            foreach my $sl (keys %$sl_len_hash) {
                $sum_subtract
                  += $se * $length
                   * $sl * $sl_len_hash->{$sl}
                   * $cb_bnok_two_arg->($se, $sl);
            }
        }
        
        $sum_subtree += ($length ** 2) * $se * $mhyperg;

        $sum_subtract
          += $mhyperg2
           * ($length ** 2)
           * ($se ** 2);

        $sum_self += $se * ($length ** 2) * $mhyperg;
        $sum_self_third_case
          += $length ** 2
           * $se  ** 2
           * $mhyperg2;
    }
    
    my $jj = -1;
    for my $se (@by_se_keys) {
        $jj++;
        #  cb_bnok_two_arg checks for this condition,
        #  but this way we avoid a sub call
        #  (which maybe matters?)
        if ($s - $se - $se >= 0) {
            $sum_same_class_third_case
              += $by_se{$se} ** 2
               * $cb_bnok_two_arg->($se, $se);
        }

        next if !$jj;
        foreach my $jji (0..$jj-1) {
            my $sl = $by_se_keys[$jji];
            $sum_third_case
              += $by_se{$se}
               * $by_se{$sl}
               * $cb_bnok_two_arg->($se, $sl);
        }
    }

    $sum_same_class_third_case
      = ($sum_same_class_third_case - $sum_self_third_case) / 2
       + $sum_self_third_case;

    $sum_third_case += $sum_same_class_third_case;

    my $total_sum = 2 * ($sum_third_case - $sum_subtract + $sum_subtree) - $sum_self;

    my $expected = 4 * $total_sum / ($r**2)  - ($exp_mean ** 2);
    
    if ($expected < 0) {
        $expected = 0
    }
    else {
        $expected = sqrt $expected;
    };

    $cache->{$r} = $expected;

    return $expected;
}

sub get_bnok_ratio_callback_one_val {
    my ($self, %args) = @_;

    my $s = $args{s} // $self->get_terminal_element_count;
    my $r = $args{r} // $args{sample_count};
    \my @lgamma_arr = $self->_get_lgamma_arr(max_n => $s);

    #  use logs to avoid expensive binomial ratio calcs
    #  results are the same to about 7dp.
    my $bnok_sr
      =      $lgamma_arr[$s]
        - (  $lgamma_arr[$r]
           + $lgamma_arr[$s - $r]
        );
    #  some precalcs
    my $exp_bnok_sr = exp -$bnok_sr;
    my $sr1 = $s - $r + 1;

    #  close over a few vars
    my $sub = sub {
        my ($se) = @_;

        if ($se < $sr1) {
            return
              exp (
                     $lgamma_arr[$s-$se]
                - (  $lgamma_arr[$r-1]
                   + $lgamma_arr[$sr1 - $se]
                  )
                - $bnok_sr
              );            
        }
        elsif ($se == $sr1) {
            return $exp_bnok_sr;
        }
        return 0;
    };

    return $sub;
}


sub get_bnok_ratio_callback_two_val {
    my ($self, %args) = @_;

    my $s = $args{s} // $self->get_terminal_element_count;
    my $r = $args{r} // $args{sample_count};
    \my @lgamma_arr = $self->_get_lgamma_arr(max_n => $s);

    #  use logs to avoid expensive binomial ratio calcs
    #  results are the same to about 7dp.
    my $bnok_sr
      =      $lgamma_arr[$s]
        - (  $lgamma_arr[$r]
           + $lgamma_arr[$s - $r]
        );
    #  some precalcs
    my $exp_bnok_sr = exp -$bnok_sr;
    my $sr2 = $s - $r + 2;
    my $rminus2 = $r - 2;
    my %cache;

    #  close over a few vars
    my $sub = sub {
        #my ($se, $sl) = @_;
        my $sesl = $_[0] + $_[1];

        return $cache{$sesl} if $cache{$sesl};
        return $cache{$sesl} = 0
          if $sr2 < $sesl;
        return $cache{$sesl} = $exp_bnok_sr
          if $sr2 == $sesl;
        #return ($r-1) / $exp_bnok_sr
        #  if $s - $se - $sl == $r-1;
        return
          $cache{$sesl} =
            exp (  $lgamma_arr[$s   - $sesl]
              - (  $lgamma_arr[$rminus2]
                 + $lgamma_arr[$sr2 - $sesl]
                )
              - $bnok_sr
            );
    };

    return $sub;
}


#  Let the system take care of most of the memory stuff.
sub DESTROY {
    my $self = shift;

    #  let the system handle global destruction
    return if ${^GLOBAL_PHASE} eq 'DESTRUCT';

    #  Get a ref to each node to linearise destruction of each node at the end.
    #  Speeds up destruction of large trees by avoiding recursion.
    #  Avoid method calls on $self just in case.  
    my %d;
    my @nodes_by_depth
      = sort {($d{$b} //= $b->get_depth) <=> ($d{$a} //= $a->get_depth)}
        values %{$self->{TREE_BY_NAME}};
    undef %d;

    #  clear the ref to the parent basedata object
    $self->set_param( BASEDATA_REF => undef );

    $self->{TREE}         = undef;    # empty the ref to the tree
    $self->{TREE_BY_NAME} = undef;    #  empty the list of nodes
    $self->{_cache}       = undef;    #  and the cache

    #  Clean up the caches before final cleanup
    foreach my $node (@nodes_by_depth) {
        next if !$node;  #  just in case
        $node->delete_cached_values;
    }
    #  Now make the nodes go out of scope from the bottom up
    #  so we avoid recursion in the cleanup.
    shift @nodes_by_depth while @nodes_by_depth;

    return;
}

# takes a hash mapping names of nodes currently in this tree to
# desired names, renames nodes accordingly.
sub remap_labels_from_hash {
    my $self       = shift;
    my %args       = @_;
    my $remap_hash = $args{remap};

    foreach my $r ( keys %$remap_hash ) {
        next if !$self->exists_node_name_aa ($r);

        my $new_name = $remap_hash->{$r};
        next if !defined $new_name || $new_name eq $r;
        
        $self->rename_node (
            old_name => $r,
            new_name => $new_name,
        );
    }

    # clear all cached values across self and nodes
    $self->delete_all_cached_values;

    return $self;
}

# wrapper around get_named_nodes for the purpose of polymorphism in
# the auto-remap logic.
sub get_labels {
    my $self = shift;
    my $named_nodes = $self->get_named_nodes;
    return wantarray ? keys %$named_nodes : [keys %$named_nodes];
}

#  mean across the whole tree
sub get_mean_nearest_neighbour_distance {
    my $self = shift;

    state $cache_key = 'MEAN_NEAREST_NBR_DIST';
    my $mean_dist = $self->get_cached_value ($cache_key);
    return $mean_dist if defined $mean_dist;

    #  keep the components on the tree
    my $dist_cache = $self->get_cached_value_dor_set_default_aa (
        NEAREST_NBR_DISTANCE_CACHE => {},
    );

    my $terminals = $self->get_terminal_nodes;
    
    my %cum_path_cache;

    my %sib_dist_cache;

    #  work with highest node with >1 children        
    my $root = $self->get_root_node;
    while ($root->get_child_count == 1) {
        my $child_arr = $root->get_children;
        $root = $child_arr->[0];
    }
    
    #  warm up the caches to avoid recursion (should be conditional?)
    foreach my $node (rikeysort {$_->get_depth} $self->get_node_refs) {
        my $xx = $node->get_shortest_path_length_to_terminals_aa;
    }

  TERMINAL:
    foreach my $name (keys %$terminals) {
        my $distance = $dist_cache->{$name};

        next TERMINAL if defined $distance;

        my $node = $terminals->{$name};

        my $cum_path
          = $cum_path_cache{$name}
            //= [reductions {$a+$b} $node->get_path_length_array_to_root_node_aa];

        #  start one below as we increment at the start of the loop
        my $target_idx = -@$cum_path - 1;
        my $min_dist;


      SIB_SEARCH:
        while ($node ne $root) {
            $target_idx++;

            my $min_sib_dist = $sib_dist_cache{$node};

            if (!defined $min_sib_dist) {
                my @sibs = $node->get_siblings;
                if (!@sibs) { # an only-child
                    $node = $node->get_parent;
                    next SIB_SEARCH;
                }
                $min_sib_dist
                  = min
                    map {$_->get_shortest_path_length_to_terminals_aa}
                    @sibs;
                $sib_dist_cache{$node} = $min_sib_dist;
            }
            
            $min_dist //= $min_sib_dist + $cum_path->[$target_idx];
            $min_dist = min ($min_dist, $min_sib_dist + $cum_path->[$target_idx]);

            #  end if the the parent's sibs cannot contain a shorter path
            #  i.e., even if the parent has zero-length sibs,
            #  its own length is too great
            last SIB_SEARCH
              if $min_dist < $cum_path->[1+$target_idx];
            $node = $node->get_parent; 
        }
        $dist_cache->{$name} = $min_dist;
    }

    my $mean = (sum values %$dist_cache) / scalar keys %$dist_cache;

    $self->set_cached_value ($cache_key => $mean);

    return $mean;
}

sub branches_are_nonnegative {
    my $self = shift;

    state $cache_key = 'BRANCHES_ARE_NONNEGATIVE';
    my $non_neg = $self->get_cached_value ($cache_key);

    return $non_neg if defined $non_neg;

    $non_neg = List::Util::all {$_->get_length >= 0} $self->get_node_refs;
    $non_neg //= 0;
    $self->set_cached_value($cache_key => $non_neg);

    return $non_neg;
}

sub get_nonzero_length_count {
    my $self = shift;
    state $cachename = 'NONZERO_BRANCH_LENGTH_COUNT';
    my $count = $self->get_cached_value ($cachename);
    return $count if defined $count;
    $count = grep { $_->get_length } $self->get_node_refs;
    $self->set_cached_value ($cachename => $count);
    return $count;
}

1;

__END__

=head1 NAME

Biodiverse::????

=head1 SYNOPSIS

  use Biodiverse::????;
  $object = Biodiverse::Tree->new();

=head1 DESCRIPTION

TO BE FILLED IN

=head1 METHODS

=over

=item remap_labels_from_hash

Given a hash mapping from names of labels currently in this tree to
desired new names, renames the labels accordingly.

=back

=head1 REPORTING ERRORS

Use the issue tracker at http://www.purl.org/biodiverse

=head1 COPYRIGHT

Copyright (c) 2010 Shawn Laffan. All rights reserved.  

=head1 LICENSE

This program is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

For a full copy of the license see <http://www.gnu.org/licenses/>.

=cut
