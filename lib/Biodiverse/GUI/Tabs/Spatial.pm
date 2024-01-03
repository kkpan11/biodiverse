package Biodiverse::GUI::Tabs::Spatial;
use 5.014;
use strict;
use warnings;

use English ( -no_match_vars );

our $VERSION = '4.99_001';

use Gtk2;
use Carp;
use Scalar::Util qw /blessed looks_like_number refaddr weaken/;
use List::Util qw /max/;
use Time::HiRes;
use Sort::Key::Natural qw /natsort natkeysort/;
use Ref::Util qw /is_ref is_hashref is_arrayref/;

use Biodiverse::GUI::GUIManager;
#use Biodiverse::GUI::ProgressDialog;
use Biodiverse::GUI::Grid;
use Biodiverse::GUI::Overlays;
use Biodiverse::GUI::Project;
use Biodiverse::GUI::SpatialParams;
use Biodiverse::GUI::Tabs::CalculationsTree;

use Biodiverse::Spatial;
use Biodiverse::Utilities qw/sort_list_with_tree_names_aa/;

#use Data::Dumper;

use parent qw {
    Biodiverse::GUI::Tabs::Tab
    Biodiverse::GUI::Tabs::Labels
};


our $NULL_STRING = q{};

use constant COLOUR_BLACK => Gtk2::Gdk::Color->new(0,0,0);
use constant COLOUR_WHITE => Gtk2::Gdk::Color->new(255*257, 255*257, 255*257);
use constant COLOUR_GRAY  => Gtk2::Gdk::Color->new(210*257, 210*257, 210*257);
use constant COLOUR_RED   => Gtk2::Gdk::Color->new(255*257,0,0);
#use constant COLOUR_FAILED_DEF_QUERY => Gtk2::Gdk::Color->new((0.9 * 255 * 257) x 3); # same as cluster grids
use constant COLOUR_FAILED_DEF_QUERY => Gtk2::Gdk::Color->new(255*257, 255*257, 255*257);



##################################################
# Initialisation
##################################################

sub new {
    my $class = shift;
    my $output_ref = shift; # will be undef if none specified

    my $self = {gui => Biodiverse::GUI::GUIManager->instance()};
    $self->{project} = $self->{gui}->get_project();
    bless $self, $class;

    # (we can have many Analysis tabs open, for example. These have a different object/widgets)
    $self->{xmlPage} = Gtk2::Builder->new();
    $self->{xmlPage}->add_from_file($self->{gui}->get_gtk_ui_file('hboxSpatialPage.ui'));
    $self->{xmlLabel} = Gtk2::Builder->new();
    $self->{xmlLabel}->add_from_file($self->{gui}->get_gtk_ui_file('hboxSpatialLabel.ui'));

    my $page  = $self->get_xmlpage_object('hboxSpatialPage');
    my $label = $self->{xmlLabel}->get_object('hboxSpatialLabel');
    my $label_text = $self->{xmlLabel}->get_object('lblSpatialName')->get_text;
    my $label_widget = Gtk2::Label->new ($label_text);
    $self->{tab_menu_label} = $label_widget;

    # Add to notebook
    $self->add_to_notebook (
        page         => $page,
        label        => $label,
        label_widget => $label_widget,
    );

    my ($elt_count, $completed);  #  used to control display

    if (not defined $output_ref) {
        # We're being called as a NEW output
        # Generate a new output name
        my $bd = $self->{basedata_ref} = $self->{project}->get_selected_base_data;

        if (not blessed ($bd)) {  #  this should be fixed now
            $self->on_close;
            croak "Basedata ref undefined - click on the basedata object in "
                    . "the outputs tab to select it (this is a bug)\n";
        }

        #  check if it has rand outputs already and warn the user
        if (my @a = $bd->get_randomisation_output_refs) {
            my $response
                = $self->{gui}->warn_outputs_exist_if_randomisation_run(
                    $self->{basedata_ref}->get_param ('NAME')
                );
            if ($response ne 'yes') {
                $self->on_close;
                croak "User cancelled operation\n";
            }
        }

        $self->{output_name} = $self->{project}->make_new_output_name(
            $self->{basedata_ref},
            'Spatial'
        );
        say "[Spatial tab] New spatial output " . $self->{output_name};

        $self->queue_set_pane(1, 'vpaneSpatial');
        $self->{existing} = 0;
        $self->get_xmlpage_object('hbox_spatial_tab_bottom')->hide;
        $self->get_xmlpage_object('toolbarSpatial')->hide;
    }
    else {
        # We're being called to show an EXISTING output

        # Register as a tab for this output
        $self->register_in_outputs_model($output_ref, $self);


        $elt_count = $output_ref->get_element_count;
        $completed = $output_ref->get_param ('COMPLETED');
        #  backwards compatibility - old versions did not have this flag
        $completed //= 1;

        $self->{output_name} = $output_ref->get_param('NAME');
        $self->{basedata_ref} = $output_ref->get_param('BASEDATA_REF');
        say "[Spatial tab] Existing spatial output - " . $self->{output_name}
              . ". Part of Basedata set - "
              . ($self->{basedata_ref}->get_param ('NAME') || "no name");

        if ($elt_count and $completed) {
            $self->queue_set_pane(0.01, 'vpaneSpatial');
        }
        else {
            $self->queue_set_pane(1, 'vpaneSpatial');
        }
        $self->{existing} = 1;
    }
    $self->{output_ref} = $output_ref;

    # Initialise widgets
    $self->{title_widget} = $self->{xmlPage} ->get_object('txtSpatialName');
    $self->{label_widget} = $self->{xmlLabel}->get_object('lblSpatialName');

    $self->{title_widget}->set_text($self->{output_name} );
    $self->{label_widget}->set_text($self->{output_name} );
    $self->{tab_menu_label}->set_text($self->{output_name} );

    $self->set_label_widget_tooltip;


    # Spatial parameters
    my ($initial_sp1, $initial_sp2, @spatial_conditions, $defq_object);
    my $initial_def1 = $NULL_STRING;
    if ($self->{existing}) {

        @spatial_conditions = @{$output_ref->get_spatial_conditions};
        #  allow for empty conditions
        $initial_sp1
            = defined $spatial_conditions[0]
            ? $spatial_conditions[0]->get_conditions_unparsed()
            : $NULL_STRING;
        $initial_sp2
            = defined $spatial_conditions[1]
            ? $spatial_conditions[1]->get_conditions_unparsed()
            : $NULL_STRING;

        my $definition_query = $output_ref->get_param ('DEFINITION_QUERY');
        $initial_def1
            = defined $definition_query
            ? $definition_query->get_conditions_unparsed()
            : $NULL_STRING;
        $defq_object = $definition_query;
    }
    else {
        my $cell_sizes = $self->{basedata_ref}->get_param('CELL_SIZES');
        my $cell_x = $cell_sizes->[0];
        $cell_x =~ s/,/\./;  #  convert radix char to c-locale used in rest of the system
        $initial_sp1
          = "sp_self_only ()\n"
          . "# sp_self_only will generate a single cell neighbour set";
        $initial_sp2 = $cell_x > 0
          ?   "#  Specify a neighbour set 2 for turnover and related window calculations\n"
            . "#  Uncomment the line for it to have an effect\n"
            . "#  sp_circle (radius => $cell_x)\n"
          : $NULL_STRING;
    }

    $self->{spatial1} = Biodiverse::GUI::SpatialParams->new(
        initial_text => $initial_sp1,
        condition_object => $spatial_conditions[0],
    );
    my $start_hidden = not (length $initial_sp2);
    $self->{spatial2} = Biodiverse::GUI::SpatialParams->new(
        initial_text => $initial_sp2,
        start_hidden => $start_hidden,
        condition_object => $spatial_conditions[1],
    );

    $self->get_xmlpage_object('frameSpatialParams1')->add(
        $self->{spatial1}->get_object
    );
    $self->get_xmlpage_object('frameSpatialParams2')->add(
        $self->{spatial2}->get_object
    );

    $start_hidden = not (length $initial_def1);
    $self->{definition_query1}
        = Biodiverse::GUI::SpatialParams->new(
            initial_text => $initial_def1,
            start_hidden => $start_hidden,
            is_def_query => 'is_def_query',
            condition_object => $defq_object,
        );
    $self->get_xmlpage_object('frameDefinitionQuery1')->add(
        $self->{definition_query1}->get_object
    );

    #  add the basedata ref
    foreach my $sp (qw /spatial1 spatial2 definition_query1/) {
        $self->{$sp}->set_param(BASEDATA_REF => $self->{basedata_ref});
    }

    $self->{hover_neighbours} = 'Both';
    $self->{hue} = Gtk2::Gdk::Color->new(65535, 0, 0); # red, for Sat mode

    $self->{calculations_model}
        = Biodiverse::GUI::Tabs::CalculationsTree::make_calculations_model (
            $self->{basedata_ref},
            $output_ref,
    );

    Biodiverse::GUI::Tabs::CalculationsTree::init_calculations_tree(
        $self->get_xmlpage_object('treeCalculations'),
        $self->{calculations_model},
    );

    #  only set it up if it exists (we get errors otherwise)
    if ($completed and $elt_count) {
        eval {
            $self->init_grid();
        };
        if ($EVAL_ERROR) {
            $self->{gui}->report_error ($EVAL_ERROR);
            $self->on_close;
        }
    }
    $self->init_lists_combo();
    #$self->make_output_indices_array();
    $self->init_output_indices_combo();

    $self->queue_set_pane(0.5, 'spatial_hpaned');
    $self->queue_set_pane(1  , 'spatial_vpanePhylogeny');

    $self->setup_dendrogram;

    # Connect signals
    $self->{xmlLabel}->get_object('btnSpatialClose')->signal_connect_swapped(
            clicked => \&on_close, $self);

    my %widgets_and_signals = (
        btnSpatialRun   => {clicked => \&on_run},
        txtSpatialName  => {changed => \&on_name_changed},
        comboLists      => {changed => \&on_active_list_changed},
        comboIndices    => {changed => \&on_active_index_changed},

        btnSelectToolSP  => {clicked => \&on_select_tool},
        btnPanToolSP     => {clicked => \&on_pan_tool},
        btnZoomInToolSP  => {clicked => \&on_zoom_in_tool},
        btnZoomOutToolSP => {clicked => \&on_zoom_out_tool},
        btnZoomFitToolSP => {clicked => \&on_zoom_fit_tool},

        menuitem_spatial_overlays => {activate => \&on_overlays},
        menuitem_spatial_colour_mode_hue  => {toggled  => \&on_colour_mode_changed},
        menuitem_spatial_colour_mode_sat  => {activate => \&on_colour_mode_changed},
        menuitem_spatial_colour_mode_grey => {toggled  => \&on_colour_mode_changed},

        menuitem_spatial_cell_outline_colour  => {activate => \&on_set_cell_outline_colour},
        menuitem_spatial_excluded_cell_colour => {activate => \&on_set_excluded_cell_colour},
        menuitem_spatial_undef_cell_colour    => {activate => \&on_set_undef_cell_colour},
        menuitem_spatial_cell_show_outline    => {toggled  => \&on_set_cell_show_outline},
        menuitem_spatial_show_legend          => {toggled  => \&on_show_hide_legend},

        button_spatial_options => {clicked => \&run_options_dialogue},
    );

    #  bodge - should set the radio group
    for my $n (0..6) {
        my $widget_name = "radio_colour_stretch$n";
        $widgets_and_signals{$widget_name} = {toggled => \&on_menu_stretch_changed};
    }

    my @nbr_menu_options = qw /
        menuitem_nbr_highlight_all
        menuitem_nbr_highlight_set1
        menuitem_nbr_highlight_set2
        menuitem_nbr_highlight_off
    /; #/
    for my $w (@nbr_menu_options) {
        $widgets_and_signals{$w} = {toggled  => \&on_menu_neighbours_changed};
    }

    while (my ($widget_name, $args) = each %widgets_and_signals) {
        my $widget = $self->get_xmlpage_object($widget_name);
        warn "Cannot connect $widget_name\n" if !defined $widget;
        $widget->signal_connect_swapped(
            %$args,
            $self,
        );
    }

    #  We don't have the grid for new outputs
    #  Could perhaps move this to where the grid is initialised
    if ($self->{grid}) {
        $self->{grid}->set_legend_mode('Hue');
        $self->recolour();
    }

    $self->{drag_modes} = {
        Select  => 'click',
        Pan     => 'pan',
        ZoomIn  => 'select',
        ZoomOut => 'click',
        ZoomFit => 'click',
    };

    $self->choose_tool('Select');

    $self->{menubar} = $self->get_xmlpage_object('menubar_spatial');
    $self->update_export_menu;
    $self->update_tree_menu;

    say "[Spatial tab] - Loaded tab - Spatial Analysis";

    return $self;
}

sub update_tree_menu {
    my $self = shift;

    my $menubar = $self->{menubar};
    my $output_ref = $self->{output_ref};
    return if !$output_ref;

    my $tree_menu = $self->{tree_menu};

    if (!$tree_menu) {
        $tree_menu  = Gtk2::MenuItem->new_with_label('Tree');
        $menubar->append($tree_menu);
        $self->{tree_menu} = $tree_menu;
    }

    if (($output_ref->get_param('COMPLETED') // 1) != 1) {
        #  completed == 2 for clusters analyses with matrices only
        $tree_menu->set_sensitive(0);
    }
    else {
        my $submenu = Gtk2::Menu->new;

        $self->_add_items_to_menu (
            menu  => $submenu,
            items => scalar $self->get_tree_menu_items,
        );

        $tree_menu->set_submenu($submenu);
        $tree_menu->set_sensitive(1);
    }

    $menubar->show_all();
}

sub get_tree_menu_items {
    my $self = shift;

    my @menu_items = (
        {
            type     => 'Gtk2::CheckMenuItem',
            label    => 'Show legend',
            tooltip  => 'Show or hide the legend on the tree plot (if one is relevant)',
            event    => 'toggled',
            callback => \&on_show_tree_legend_changed,
            active   => 1,
            self_key => 'checkbox_show_tree_legend',
        },
        {
            type     => 'Gtk2::CheckMenuItem',
            label    => 'Log scale',
            tooltip  => "Log scale the colours.\n"
                . "Uses the min and max determined by the Colour stretch choice.",
            event    => 'toggled',
            callback => sub {
                my ($self, $menuitem) = @_;
                $self->{use_tree_log_scale} = $menuitem->get_active;
            },
            active   => 1,
        },
        {
            type     => 'Gtk2::CheckMenuItem',
            label    => 'Invert colour stretch',
            tooltip  => "Invert (flip) the colour range. Has no effect on categorical colouring.",
            event    => 'toggled',
            callback => sub {
                my ($self, $menuitem) = @_;
                $self->{tree_invert_colours} = $menuitem->get_active;
            },
            active   => 0,
        },
        {
            type  => 'submenu_radio_group',
            label => 'Colour mode',
            items => [  #  could be refactored
                {
                    type     => 'Gtk2::RadioMenuItem',
                    label    => 'Hue',
                    event    => 'activate',
                    callback => \&on_tree_colour_mode_changed,
                },
                {
                    type     => 'Gtk2::RadioMenuItem',
                    label    => 'Sat...',
                    event    => 'activate',
                    callback => \&on_tree_colour_mode_changed,
                },
                {
                    type     => 'Gtk2::RadioMenuItem',
                    label    => 'Grey',
                    event    => 'activate',
                    callback => \&on_tree_colour_mode_changed,
                }
            ],
        },
        {
            type     => 'Gtk2::MenuItem',
            label    => 'Set tree branch line widths',
            tooltip  => "Set the width of the tree branches.\n"
                . "Does not affect the vertical connectors.",
            event    => 'activate',
            callback => \&on_set_tree_line_widths,
        },
        {
            type => 'Gtk2::SeparatorMenuItem'
        },
        {
            type     => 'Gtk2::MenuItem',
            label    => 'Export',
            tooltip  => 'Export the currently displayed tree',
            event    => 'activate',
            callback => sub {
                my $tree_ref = $self->get_current_tree;
                return Biodiverse::GUI::Export::Run($tree_ref);
            },
        },
    );

    return wantarray ? @menu_items : \@menu_items;
}

sub _add_items_to_menu {
    my ($self, %args) = @_;
    my @menu_items = @{$args{items}};
    my $menu = $args{menu};
    my $radio_group = $args{radio_group};

  ITEM:
    foreach my $item (@menu_items) {
        my $type = $item->{type} // 'Gtk2::MenuItem';

        if ($type eq 'submenu_radio_group') {
            #  a bit messy
            my $menu_item = Gtk2::MenuItem->new($item->{label} // ());
            $menu->append($menu_item);
            my $radio_submenu = Gtk2::Menu->new;
            $self->_add_items_to_menu(
                items       => $item->{items},
                menu        => $radio_submenu, #  temp
                radio_group => [],
            );
            $menu_item->set_submenu($radio_submenu);
            next ITEM;
        }

        my $menu_item;
        if ($type =~ /Radio/) {
            $menu_item = $type->new($radio_group, $item->{label} // ());
            push @$radio_group, $menu_item;
        }
        else {
            $menu_item = $type->new($item->{label} // ());
        }
        $menu->append($menu_item);

        next ITEM if $type =~ /Separator/;

        if (my $key = $item->{self_key}) {
            $self->{$key} = $menu_item,
        }
        if (my $tooltip = $item->{tooltip}) {
            $menu_item->set_has_tooltip(1);
            $menu_item->set_tooltip_text($tooltip);
        }
        if (($type =~ 'Check') && exists $item->{active}) {
            $menu_item->set_active($item->{active});
        }
        if (my $callback = $item->{callback}) {
            my $args = $item->{callback_args};
            $menu_item->signal_connect_swapped(
                $item->{event} => $callback,
                $args // $self
            );
        }
    }

}

#  doesn't work yet
sub screenshot {
    my $self = shift;
    return;


    my $mywidget = $self->{grid}{back_rect};
    my ($width, $height) = $mywidget->window->get_size;

    # create blank pixbuf to hold the image
    my $gdkpixbuf = Gtk2::Gdk::Pixbuf->new (
        'rgb',
        0,
        8,
        $width,
        $height,
    );

    $gdkpixbuf->get_from_drawable
        ($mywidget->window, undef, 0, 0, 0, 0, $width, $height);

    my $file = 'testtest.png';
    print "Saving screenshot to $file";
    $gdkpixbuf->save ($file, 'png');

    return;
}


sub on_show_hide_parameters {
    my $self = shift;

    my $frame = $self->get_xmlpage_object('frame_spatial_parameters');
    my $widget = $frame->get_label_widget;
    my $active = $widget->get_active;

    my $table = $self->get_xmlpage_object('tbl_spatial_parameters');
    $table->set_visible ($active);

    return;
}


sub setup_dendrogram {
    my $self = shift;

    $self->update_dendrogram_combo;

    $self->init_dendrogram();
    # Register callbacks when selected phylogeny is changed
    $self->{phylogeny_callback} = sub { $self->on_selected_phylogeny_changed(); };
    $self->{project}->register_selection_callback(
        'phylogeny',
        $self->{phylogeny_callback},
    );
    $self->get_xmlpage_object('comboTreeSelect')->signal_connect_swapped(
        changed => \&on_selected_phylogeny_changed,
        $self,
    );
    $self->on_selected_phylogeny_changed();
}

sub update_dendrogram_combo {
    my $self = shift;

    my $xmlpage = $self->{xmlPage};
    my $combobox = $xmlpage->get_object('comboTreeSelect');

    #  Clear the curent entries.
    #  We need to load a new ListStore to avoid crashes due
    #  to them being destroyed somewhere in the refresh process
    my $model = Gtk2::ListStore->new('Glib::String');
    $combobox->set_model ($model);

    my $combo_items = 0;
    foreach my $option ('project', 'none', 'hide panel') {
        $combobox->append_text($option);
        $combo_items ++;
    }

    no autovivification;

    my $output_ref = $self->{output_ref};
    if ($output_ref && $output_ref->can('get_embedded_tree') && $output_ref->get_embedded_tree) {
        $combobox->prepend_text('analysis');
        $combo_items++;
    }

    if ($self->get_trees_are_available_to_plot) {
        $combobox->set_active(0);
    }
    else {
        #  Last one is 'hide panel'
        #  It would be nice to extract from the model itself, if someone could work that out...
        $combobox->set_active ($combo_items-1);
    }
}

# For the phylogeny tree:
sub init_dendrogram {
    my $self = shift;

    my $frame       = $self->get_xmlpage_object('spatialPhylogenyFrame');
    my $graph_frame = $self->get_xmlpage_object('spatialPhylogenyGraphFrame');
    my $hscroll     = $self->get_xmlpage_object('spatialPhylogenyHScroll');
    my $vscroll     = $self->get_xmlpage_object('spatialPhylogenyVScroll');

    my $list_combo  = undef;  #  these are under the control of the spatial plot, not the dendrogram
    my $index_combo = undef;

    my $hover_closure       = sub { $self->on_phylogeny_hover(@_); };
    my $highlight_closure   = sub { $self->on_phylogeny_highlight(@_); };
    my $ctrl_click_closure  = sub { $self->on_phylogeny_popup(@_); };
    my $click_closure       = sub { $self->on_phylogeny_click(@_); };
    my $select_closure      = sub { $self->on_phylogeny_select(@_); };

    $self->{dendrogram} = Biodiverse::GUI::Dendrogram->new(
        main_frame  => $frame,
        graph_frame => $graph_frame,
        hscroll     => $hscroll,
        vscroll     => $vscroll,
        grid        => undef,
        list_combo  => undef,  #  the combos are under the control of the spatial plot, not the dendrogram
        index_combo => undef,
        hover_func      => $hover_closure,
        highlight_func  => $highlight_closure,
        ctrl_click_func => $ctrl_click_closure,
        click_func      => $click_closure,
        select_func     => $select_closure,
        parent_tab      => $self,
        want_legend     => 1,
        no_use_slider_to_select_nodes => 1,
    );

    $self->{dendrogram}{page} = $self;
    weaken $self->{dendrogram}{page};

    #  cannot colour more than one in a phylogeny
    $self->{dendrogram}->set_num_clusters (1);

    $self->{no_dendro_legend_for} = {
        '<i>Turnover</i>'              => 1,
        '<i>Branches in nbr set 1</i>' => 1,
        'Turnover'                     => 1,
        'Branches in nbr set 1'        => 1,
    };

    $self->init_branch_colouring_menu;
    $self->init_dendrogram_legend;
    
    return 1;
}

sub init_branch_colouring_menu {
    my $self = shift;
    my %args = @_;

    return if !defined $self->{output_ref};
    return if blessed ($self) =~ /Matrix/;

    my $xml_page = $self->{xmlPage};
    my $bottom_hbox = $xml_page->get_object('hbox_spatial_tab_bottom');

    my $menubar   = $self->{branch_colouring_menu};
    my $have_menu = !!$menubar;

    return 1 if !($args{refresh} || !$menubar);

    #  clean up pre-existing
    if ($have_menu) {
        $_->destroy
            foreach @{$self->{branch_colouring_extra_widgets} // []};
        $menubar->destroy if $menubar;
    }

    my $label = Gtk2::Label->new('Branch colouring: ');

    $menubar = Gtk2::MenuBar->new;
    my $menu = Gtk2::Menu->new;
    my $menuitem = Gtk2::MenuItem->new_with_label('Branch colouring: ');
    $menuitem->set_submenu ($menu);
    $menubar->append($menuitem);
    my $menu_action = sub {
        my $args = shift;
        my ($self, $listname, $output_ref) = @$args;
        my $chk_show_legend = $self->{checkbox_show_tree_legend};
        my $show_legend = $chk_show_legend ? $chk_show_legend->get_active : 1;
        if ($show_legend) {
            $self->{dendrogram}->update_legend;  #  need dendrogram to pass on coords
            $self->{dendrogram}->get_legend->show;
        }
        $self->{current_branch_colouring_source} = [$output_ref, $listname];
        my $output_name = $output_ref->get_name;
        $label->set_markup ("$listname <i>(source: $output_name)</i>");
    };

    #  need to keep in synch with $self->{no_dendro_legend_for}
    my $default_text
      = $self->{output_ref}->get_spatial_conditions_count > 1
      ? '<i>Turnover</i>'
      : '<i>Branches in nbr set 1</i>';
    $label->set_markup ($default_text);
    my $default_text_sans_markup = $default_text =~ s/<.?i>//gr;
    my $sel_group = [];

    my $menu_item_label = Gtk2::Label->new($default_text);
    my $menu_item
        = Gtk2::RadioMenuItem->new_with_label($sel_group, $default_text_sans_markup);
    push @$sel_group, $menu_item;
    $menu_item->set_use_underline(0);
    # $menu_item->set_label($menu_item_label);
    $menu->append($menu_item);
    $menu_item->signal_connect_swapped(
        activate => sub {
            $self->{dendrogram}->get_legend->hide;
            $self->{current_branch_colouring_source} = undef;
            $label->set_markup ($default_text);
        },
    );

    $menu->append(Gtk2::SeparatorMenuItem->new);
    $menu->append(Gtk2::MenuItem->new_with_label('Lists in this output:'));

    state $re_skip_list = qr/(^RECYCLED_SET$)|(SPATIAL_RESULTS|CANAPE>>)$/;

    my $output_ref = $self->{output_ref};

    my $list_names
      = $output_ref->get_hash_lists_across_elements;
    foreach my $list_name (natsort @$list_names) {
        next if $list_name =~ /$re_skip_list/;

        my $menu_item = Gtk2::RadioMenuItem->new($sel_group, $list_name);
        push @$sel_group, $menu_item;  #  first one is default
        $menu_item->set_use_underline(0);
        $menu->append($menu_item);
        $menu_item->signal_connect_swapped(
            activate => $menu_action, [$self, $list_name, $output_ref],
        );
    }

    $menu->append(Gtk2::SeparatorMenuItem->new);
    $menu->append(Gtk2::MenuItem->new_with_label('Lists across project basedatas:'));

    #  now add the lists from other spatial outputs in the project,
    #  organised by their parent basedatas
    my $own_bd = $output_ref->get_basedata_ref;
    my @project_basedatas
        = @{$self->{project}->get_base_data_list};
    foreach my $bd (@project_basedatas) {
        my @output_refs
            = grep {$_ ne $output_ref}
              $bd->get_spatial_output_refs;
        next if !@output_refs;

        my $bd_name = $bd->get_name;
        my $bd_submenu = Gtk2::Menu->new;
        my $bd_submenu_item = Gtk2::MenuItem->new_with_label($bd_name);
        $bd_submenu_item->set_use_underline(0);
        my $item_count;

        foreach my $ref (natkeysort {$_->get_name} @output_refs) {
            my @list_names
                = natsort
                  grep {$_ !~ /$re_skip_list/}
                  $ref->get_hash_lists_across_elements;
            next if !@list_names;

            $item_count++;

            my $output_name = $ref->get_name;
            my $sp_submenu = Gtk2::Menu->new;
            my $sp_submenu_item = Gtk2::MenuItem->new_with_label($output_name);
            $sp_submenu_item->set_use_underline(0);
            $sp_submenu_item->set_submenu($sp_submenu);
            foreach my $list_name (@list_names) {
                my $menu_item = Gtk2::RadioMenuItem->new($sel_group, $list_name);
                push @$sel_group, $menu_item;
                $menu_item->set_use_underline(0);
                $menu_item->signal_connect_swapped(
                    activate => $menu_action, [$self, $list_name, $ref],
                );
                $sp_submenu->append($menu_item);
            }

            $bd_submenu->append($sp_submenu_item);
        }
        if ($item_count) {
            $bd_submenu_item->set_submenu($bd_submenu);
            $menu->append($bd_submenu_item);
        }
    }

    my $separator = Gtk2::SeparatorToolItem->new;
    foreach my $widget ($separator, $menubar, $label) {
        $bottom_hbox->pack_start ($widget, 0, 0, 0);
    }
    $bottom_hbox->show_all;
    $menu->set_sensitive(1);

    $menubar->set_has_tooltip(1);
    $menubar->set_tooltip_text ($self->_get_branch_colouring_menu_tooltip);
    $label->set_has_tooltip(1);
    $label->set_tooltip_text ($self->_get_branch_colouring_label_tooltip);

    $self->{branch_colouring_menu} = $menubar;
    $self->{branch_colouring_extra_widgets}
      = [$separator, $label];

    return 1;
}

sub _get_branch_colouring_label_tooltip {
    state $text = <<'EOT'
The current list and source used to colour the tree branches.
This can be changed using the 'Branch colouring' menu to the
immediate left of this label.
EOT
    ;
    return $text;
}

sub _get_branch_colouring_menu_tooltip {
    state $text = <<'EOT'
Select the list to visualise as colours on the tree
when hovering over the grid.

The first (default) option shows the paths connecting
the labels in the neighbour sets used for the analysis.
When there is one such set all branches are coloured blue.
When there are two such sets blue denotes branches only
in the first set, red denotes those only in the second set,
and black denotes those in both. From these one can see
the turnover of branches between the groups (cells) in
each neighbour set.

The next set of menu options are list indices in the spatial
output that belongs to this tab.  The remainder are lists
across other spatial outputs in the project, organised by their
basedata objects.  These are in the same order as in the
Outputs tab.  Basedatas and outputs with no list indices are
not shown.

If a branch is not in the list then it is highlighted
using a default colour (usually black).  If the selected
output has no labels that are also on the tree then no
highlighting is done (all branches remain black).

Right clicking on a group (cell) fixes the highlighting
in place, stopping changes to the branch colouring as
the mouse is hovered over other groups.  This allows
the tree to be exported with the current colouring.

EOT
  ;
    return $text;
}

sub init_dendrogram_legend {
    my $self = shift;
    
    my $legend = $self->{dendrogram}->get_legend;
    return if !$legend;

    #  we used to do more here
    return;
}

sub init_grid {
    my $self = shift;
    my $frame   = $self->get_xmlpage_object('gridFrame');
    my $hscroll = $self->get_xmlpage_object('gridHScroll');
    my $vscroll = $self->get_xmlpage_object('gridVScroll');

    $self->{initialising_grid} = 1;

    # Use closure to automatically pass $self (which grid doesn't know)
    my $hover_closure = sub { $self->on_grid_hover(@_); };
    my $click_closure = sub {
        Biodiverse::GUI::CellPopup::cell_clicked(
            $_[0],
            $self->{grid}->get_base_struct,
        );
    };
    my $grid_click_closure = sub { $self->on_grid_click(@_); };
    my $select_closure = sub { $self->on_grid_select(@_); };
    my $end_hover_closure = sub { $self->on_end_grid_hover(@_); };

    $self->{grid} = Biodiverse::GUI::Grid->new(
        frame => $frame,
        hscroll => $hscroll,
        vscroll => $vscroll,
        show_legend => 1,
        show_value  => 0,
        hover_func      => $hover_closure,
        click_func      => $click_closure, # Middle click
        select_func     => $select_closure,
        grid_click_func => $grid_click_closure, # Left click
        end_hover_func  => $end_hover_closure,
    );
    $self->{grid}{page} = $self;
    weaken $self->{grid}{page};

    $self->{grid}{drag_mode} = 'select';

    if ($self->{existing}) {
        my $data = $self->{output_ref};
        my $elt_count = $data->get_element_count;
        my $completed = $data->get_param ('COMPLETED');
        #  backwards compatibility - old versions did not have this flag
        $completed = 1 if not defined $completed;

        if (defined $data and $elt_count and $completed) {
            $self->{grid}->set_base_struct ($data);
        }
    }

    $self->{initialising_grid} = 0;

    my $menu_log_checkbox = $self->get_xmlpage_object('menu_colour_stretch_log_mode');
    $menu_log_checkbox->signal_connect_swapped(
        toggled => \&on_grid_colour_scaling_changed,
        $self,
    );
    my $menu_flip_checkbox = $self->get_xmlpage_object('menu_colour_stretch_flip_mode');
    $menu_flip_checkbox->signal_connect_swapped(
        toggled => \&on_grid_colour_flip_changed,
        $self,
    );

    $self->warn_if_basedata_has_gt2_axes;

    return;
}

sub set_cell_outline_menuitem_active {
    my ($self, $active) = @_;
    $self->get_xmlpage_object('menuitem_spatial_cell_show_outline')->set_active($active);
}

sub update_display_list_combos {
    my ($self, %args) = @_;

    my @methods = qw /
        update_lists_combo
        update_output_indices_combo
        init_branch_colouring_menu
    /;

    $self->SUPER::update_display_list_combos (
        %args,
        methods => \@methods,
    );
    
    return;
}

sub init_lists_combo {
    my $self = shift;


    my $combo = $self->get_xmlpage_object('comboLists');
    my $renderer = Gtk2::CellRendererText->new();
    $combo->pack_start($renderer, 1);
    $combo->add_attribute($renderer, text => 0);

    # Only do this if we aren't a new spatial analysis...
    if ($self->{existing}) {
        $self->update_lists_combo();
    }

    return;
}

sub update_lists_combo {
    my $self = shift;

    # Make the model
    $self->{output_lists_model} = $self->make_lists_model();
    my $combo = $self->get_xmlpage_object('comboLists');
    $combo->set_model($self->{output_lists_model});

    # Select the SPATIAL_RESULTS list (or the first one)
    my $iter = $self->{output_lists_model}->get_iter_first();
    my $selected = $iter;

    while ($iter) {
        my ($list) = $self->{output_lists_model}->get($iter, 0);
        if ($list eq 'SPATIAL_RESULTS' ) {
            $selected = $iter;
            last; # break loop
        }
        $iter = $self->{output_lists_model}->iter_next($iter);
    }

    if ($selected) {
        $combo->set_active_iter($selected);
    }
    $self->on_active_list_changed($combo);

    return;
}


# Generates Perl array with analyses
# (Jaccard, Endemism, CMP_XXXX) that can be shown on the grid
sub make_output_indices_array {
    my $self = shift;
    my $list_name = $self->{selected_list};
    my $output_ref = $self->{output_ref};

    # SWL: Get possible analyses by sampling all elements - this allows for asymmetric lists
    #my $bd_ref = $output_ref->get_param ('BASEDATA_REF') || $output_ref;
    my $elements = $output_ref->get_element_hash() || {};

    my %analyses_tmp;
    foreach my $elt (keys %$elements) {
        #%analyses_tmp = (%analyses_tmp, %{$elements->{$elt}{$list_name}});
        next if ! exists $elements->{$elt}{$list_name};
        my $hash = $elements->{$elt}{$list_name};
        if (scalar keys %$hash) {
            @analyses_tmp{keys %$hash} = values %$hash;
        }
    }

    #  are they numeric?  if so then we sort differently.
    my $numeric = 1;

    CHECK_NUMERIC:
    foreach my $model (keys %analyses_tmp) {
        if (not looks_like_number ($model)) {
            $numeric = 0;
            last CHECK_NUMERIC;
        }
    }

    my @analyses;
    if (scalar keys %analyses_tmp) {
        @analyses = $numeric
            ? sort {$a <=> $b} keys %analyses_tmp   #  numeric
            : sort {$a cmp $b} keys %analyses_tmp;  #  text
    }

    return [@analyses];
}

# Generates ComboBox model with analyses
# (Jaccard, Endemism, CMP_XXXX) that can be shown on the grid
sub make_output_indices_model {
    my $self = shift;
    my $list_name = $self->{selected_list};
    my $output_ref = $self->{output_ref};

    # SWL: Get possible indices by sampling all elements
    #  - this allows for asymmetric lists
    my $elements = $output_ref->get_element_hash() || {};

    my %analyses_tmp;
    foreach my $elt (keys %$elements) {
        next if ! exists $elements->{$elt}{$list_name};
        my $hash = $elements->{$elt}{$list_name};
        if (scalar keys %$hash) {
            @analyses_tmp{keys %$hash} = undef;
        }
    }

    my @analyses
      = sort_list_with_tree_names_aa ([keys %analyses_tmp]);

    # Make model for combobox
    my $model = Gtk2::ListStore->new('Glib::String');
    foreach my $x (@analyses) {
        my $iter = $model->append;
        #print ($model->get($iter, 0), "\n") if defined $model->get($iter, 0);    #debug
        $model->set($iter, 0, $x);
        #print ($model->get($iter, 0), "\n") if defined $model->get($iter, 0);      #debug
    }

    return $model;
}

# Generates ComboBox model with analyses
# (Jaccard, Endemism, CMP_XXXX) that can be shown on the grid
sub make_lists_model {
    my $self = shift;
    my $output_ref = $self->{output_ref};

    my $lists = $output_ref->get_lists_across_elements (
        no_private => 1,
        max_search => undef,
    );

    #print "Making lists model\n";
    #print join (" ", @lists) . "\n";

    # Make model for combobox
    my $model = Gtk2::ListStore->new('Glib::String');
    foreach my $x (sort @$lists) {
        my $iter = $model->append;
        $model->set($iter, 0, $x);
    }

    return $model;
}



##################################################
# Managing that vertical pane
##################################################

# Sets the vertical pane's position (0 -> all the way down | 1 -> fully up)
sub set_pane {
    my $self = shift;
    my $pos  = shift;
    my $id   = shift;

    return if !defined $id;

    my $pane = $self->get_xmlpage_object($id);
    my $max_pos = $pane->get('max-position');
    $pane->set_position( $max_pos * $pos );
    #print "[Spatial tab] Updating pane: maxPos = $max_pos, pos = $pos\n";

    return;
}

# This will schedule set_pane to be called from a temporary signal handler
# Need when the pane hasn't got it's size yet and doesn't know its max position
sub queue_set_pane {
    my $self = shift;
    my $pos = shift;
    my $id = shift;

    my $pane = $self->get_xmlpage_object($id);

    # remember id so can disconnect later
    my $sig_id = $pane->signal_connect_swapped(
        'size-allocate',
        \&Biodiverse::GUI::Tabs::Spatial::set_pane_signal,
        [$self, $id]
    );
    $self->{"set_paneSignalID$id"} = $sig_id;
    $self->{"set_panePos$id"} = $pos;

    return;
}

sub set_pane_signal {
    my $args = shift;
    shift;
    my $pane = shift;

    my ($self, $id) = ($args->[0], $args->[1]);

    $self->set_pane( $self->{"set_panePos$id"}, $id );
    $pane->signal_handler_disconnect( $self->{"set_paneSignalID$id"} );
    delete $self->{"set_panePos$id"};
    delete $self->{"set_paneSignalID$id"};

    return;
}

##################################################
# Dendrogram related
##################################################

sub on_selected_phylogeny_changed {
    my $self = shift;

    # phylogenies
    my $phylogeny = $self->get_current_tree;

    if ($self->{dendrogram}) {
        $self->{dendrogram}->clear;
    }
    if ($phylogeny) {
        $self->{dendrogram}->set_cluster($phylogeny, 'length');  #  now storing tree objects directly
        $self->set_phylogeny_options_sensitive(1);
    }
    else {
        $self->{dendrogram}->set_cluster(undef, 'length');
        $self->set_phylogeny_options_sensitive(0);
        my $str = '<i>No selected tree</i>';
        $self->get_xmlpage_object('spatial_label_VL_tree')->set_markup($str);
    }

    return;
}

sub set_phylogeny_options_sensitive {
    my $self = shift;
    my $enabled = shift;

    my $page = $self->{xmlPage};
}

## START PASTE OF PHYLO METHODS FROM LABELS

# Called by dendrogram when user hovers over a node
# Updates those info labels
sub on_phylogeny_hover {
    my $self = shift;
    my $node = shift || return;

    no warnings 'uninitialized';  #  don't complain if nodes have not been numbered

    my $map_text = '<b>Node label: </b> ' . $node->get_name;
    my $dendro_text = sprintf (
        '<b>Node Length: </b> %.4f <b>Element numbers: First</b> %d <b>Last:</b> %d',
         $node->get_total_length, # round to 4 d.p.
         $node->get_value ('TERMINAL_NODE_FIRST'),
         $node->get_value ('TERMINAL_NODE_LAST'),
    );

    $self->get_xmlpage_object('lblOutput')->set_markup($map_text);
    $self->get_xmlpage_object('spatial_label_VL_tree')->set_markup($dendro_text);

    return;
}

# many other phylogeny methods are given in Labels.pm
# Called by dendrogram when user hovers over a node
sub on_phylogeny_highlight {
    my $self = shift;
    my $node = shift;

    return if !$node;

    #say "for node $node";
    my $terminal_elements = (defined $node) ? $node->get_terminal_elements : {};

    # Hash of groups that have the selected labels
    my %groups;
    my ($iter, $label, $hash);

    my $bd = $self->get_base_ref;

    LABEL:
    foreach my $label (keys %$terminal_elements) {
        my $containing = eval {$bd->get_groups_with_label_as_hash(label => $label)};
        next LABEL if !$containing;

        #print "have label: $label\n";
        @groups{keys %$containing} = values %$containing;
    }

    $self->{grid}->mark_if_exists( \%groups, 'circle' );
    $self->{grid}->mark_if_exists( {}, 'minus' );  #  clear any nbr_set2 highlights

    return;
}

sub on_phylogeny_click {
    my $self = shift;

    if ($self->{tool} eq 'Select') {
        my $node = shift;
        $self->{dendrogram}->do_colour_nodes_below($node);
        if (!$node) {  #  clear the highlights.  Maybe should copy Clustering.pm and add a leave event
            $self->{grid}->mark_if_exists( {}, 'circle' );
            $self->{grid}->mark_if_exists( {}, 'minus');
        }
    }
    elsif ($self->{tool} eq 'ZoomOut') {
        $self->{dendrogram}->zoom_out();
    }
    elsif ($self->{tool} eq 'ZoomFit') {
        $self->{dendrogram}->zoom_fit();
    }

    return;
}

sub on_phylogeny_select {
    my $self = shift;
    my $rect = shift; # [x1, y1, x2, y2]

    if ($self->{tool} eq 'ZoomIn') {
        my $grid = $self->{dendrogram};
        $self->handle_grid_drag_zoom ($grid, $rect);
    }

    return;
}

sub on_phylogeny_popup {
    my $self = shift;
    my $node_ref = shift;
    #my $basedata_ref = $self->{base_ref};
    my $basedata_ref = $self->get_base_ref;

    my ($sources, $default_source) = get_sources_for_node($node_ref, $basedata_ref);
    Biodiverse::GUI::Popup::show_popup($node_ref->get_name, $sources, $default_source);

    return;
}

sub on_use_highlight_path_changed {
    my $self = shift;

    #  set to the complement
    $self->{use_highlight_path} = not $self->{use_highlight_path};

    #  clear any highlights
    if ($self->{dendrogram} and not $self->{use_highlight_path}) {
        $self->{dendrogram}->clear_highlights;
    }

    return;
}

sub get_sources_for_node {
    my $node_ref     = shift;
    my $basedata_ref = shift;

    my %sources;

    #print Data::Dumper::Dumper($node_ref->get_value_keys);
    $sources{Labels} = sub { show_phylogeny_labels(@_, $node_ref); };
    $sources{Groups} = sub { show_phylogeny_groups(@_, $node_ref, $basedata_ref); };
    $sources{Descendants} = sub { show_phylogeny_descendents(@_, $node_ref); };

    # Custom lists - getValues() - all lists in node's $self
    # FIXME: try to merge with CellPopup::showOutputList
    #my @lists = $node_ref->get_value_keys;
    my @lists = $node_ref->get_list_names;
    foreach my $name (@lists) {
        next if not defined $name;
        next if $name =~ /^_/; # leading underscore marks internal list

        #print "[Labels] Phylogenies: adding custom list $name\n";
        $sources{$name} = sub { show_list(@_, $node_ref, $name); };
    }

    return (\%sources, 'Labels (cluster)'); # return a default too
}

# Called by popup dialog
# Shows a custom list
# FIXME: duplicates function in Clustering.pm
sub show_list {
    my $popup = shift;
    my $node_ref = shift;
    my $name = shift;

    #my $ref = $node_ref->get_value($name);
    my $ref = $node_ref->get_list_ref (list => $name);

    my $model = Gtk2::ListStore->new('Glib::String', 'Glib::String');
    my $iter;

    if (is_hashref($ref)) {
        foreach my $key (sort keys %$ref) {
            my $val = $ref->{$key};
            #print "[Dendrogram] Adding output hash entry $key\t\t$val\n";
            $iter = $model->append;
            $model->set($iter,    0,$key ,  1,$val);
        }
    }
    elsif (is_arrayref($ref)) {
        foreach my $elt (sort @$ref) {
            #print "[Dendrogram] Adding output array entry $elt\n";
            $iter = $model->append;
            $model->set($iter,    0,$elt ,  1,'');
        }
    }
    elsif (not is_ref($ref)) {
        $iter = $model->append;
        $model->set($iter,    0, $ref,  1,'');
    }

    $popup->set_value_column(1);
    $popup->set_list_model($model);

    return;
}

# Called by popup dialog
# Shows the labels for all elements under given node
sub show_phylogeny_groups {
    my $popup        = shift;
    my $node_ref     = shift;
    my $basedata_ref = shift;

    # Get terminal elements
    my $elements = $node_ref->get_terminal_elements;

    # For each element, get its groups and put into %total_groups
    my %total_groups;
    foreach my $element (natsort keys %{$elements}) {
        my $ref = eval {$basedata_ref->get_groups_with_label_as_hash(label => $element)};

        next if !$ref || !scalar keys %$ref;

        @total_groups{keys %$ref} = undef;
    }

    # Add each label into the model
    my $model = Gtk2::ListStore->new('Glib::String', 'Glib::String');
    foreach my $label (sort keys %total_groups) {
        my $iter = $model->append;
        $model->set($iter, 0, $label, 1, q{});
    }

    $popup->set_list_model($model);
    $popup->set_value_column(1);

    return;
}

# Called by popup dialog
# Shows all elements under given node
sub show_phylogeny_labels {
    my $popup = shift;
    my $node_ref = shift;

    my $elements = $node_ref->get_terminal_elements;
    my $model = Gtk2::ListStore->new('Glib::String', 'Glib::Int');

    foreach my $element (natsort keys %{$elements}) {
        my $count = $elements->{$element};
        my $iter = $model->append;
        $model->set($iter, 0,$element,  1, $count);
    }

    $popup->set_list_model($model);
    $popup->set_value_column(1);

    return;
}

# Called by popup dialog
# Shows all descendent nodes under given node
sub show_phylogeny_descendents {
    my $popup    = shift;
    my $node_ref = shift;

    my $model = Gtk2::ListStore->new('Glib::String', 'Glib::Int');

    my $node_hash = $node_ref->get_names_of_all_descendants_and_self;

    foreach my $element (sort_list_with_tree_names_aa ([keys %$node_hash])) {
        my $count = $node_hash->{$element};
        my $iter  = $model->append;
        $model->set($iter, 0, $element, 1, $count);
    }

    $popup->set_list_model($model);
    $popup->set_value_column(1);

    return;
}

### END PASTE OF PHYLO METHODS FROM LABELS
##################################################
# Misc interaction with rest of GUI
##################################################


sub get_type {
    return "spatial";
}


sub remove {
    my $self = shift;

    eval {$self->{grid}->destroy()};
    $self->{grid} = undef;  #  convoluted, but we're getting reference cycles
    $self->{project}->delete_selection_callback('phylogeny', $self->{phylogeny_callback});

    $self->SUPER::remove;

    return;
}



##################################################
# Running analyses
##################################################
sub on_run {
    my $self = shift;

    # Load settings...
    my $output_name = $self->get_xmlpage_object('txtSpatialName')->get_text();
    $self->{output_name} = $output_name;

    # Get calculations to run
    my @to_run
        = Biodiverse::GUI::Tabs::CalculationsTree::get_calculations_to_run( $self->{calculations_model} );

    if (scalar @to_run == 0) {
        my $dlg = Gtk2::MessageDialog->new(
            undef,
            'modal',
            'error',
            'close',
            'No calculations selected',
        );
        $dlg->run();
        $dlg->destroy();
        return;
    }

    # Check spatial syntax
    return if $self->{spatial1}->syntax_check('no_ok') ne 'ok';
    return if $self->{spatial2}->syntax_check('no_ok') ne 'ok';
    return if $self->{definition_query1}->syntax_check('no_ok') ne 'ok';

    my $new_result = 1;
    my $overwrite  = 0;
    my $output_ref = $self->{output_ref};

    my $time = time();

    # Delete existing?
    if (defined $output_ref) {
        my $text = "$output_name exists.  Do you mean to overwrite it?";
        my $completed = $output_ref->get_param('COMPLETED') // 1;
        if ($self->{existing} && $completed) {

            #  drop out if we don't want to overwrite
            my $response = Biodiverse::GUI::YesNoCancel->run({
                header  => 'Overwrite? ',
                text    => $text,
                hide_no => 1,
            });
            return 0 if $response ne 'yes';
        }

        $overwrite    = 1;
        $new_result   = 0;
        $output_name .= " (overwriting)";  #  work under a temporary name
    }
    #else {
    #   $output_name .= " (tmp $time)";  #  work under a temporary name
    #}


    # Add spatial output
    $output_ref = eval {
        $self->{basedata_ref}->add_spatial_output(
            name => $output_name,
        );
    };
    if ($EVAL_ERROR) {
        $self->{gui}->report_error ($EVAL_ERROR);
        return;
    }

    my $options = $self->get_options;

    #my $defq = $self->{definition_query1}->get_validated_conditions;

    my %args = (
        calculations       => \@to_run,
        matrix_ref         => $self->{project}->get_selected_matrix,
        tree_ref           => $self->{project}->get_selected_phylogeny,
        definition_query   => $self->{definition_query1}->get_validated_conditions,
        spatial_conditions => [
            $self->{spatial1}->get_validated_conditions,
            $self->{spatial2}->get_validated_conditions,
        ],
        %$options,
    );

    # Perform the analysis
    $self->{initialising_grid} = 1;  #  desensitise the grid if it is already displayed

    say "[Spatial tab] Running calculations @to_run";

    my $success = eval {
        $output_ref->run_analysis(%args)
    };
    if ($EVAL_ERROR) {
        $self->{gui}->report_error ($EVAL_ERROR);
    }

    #  sometimes this can be missed in Biodiverse::Spatial::run_analysis.
    $self->{definition_query1}->delete_cached_values;

    #  only add to the project if successful
    if (!$success) {
        #if ($overwrite) {  #  remove the failed run
            $self->{basedata_ref}->delete_output(output => $output_ref);
        #}

        $self->{initialising_grid} = 0;
        $self->on_close;  #  close the tab to avoid horrible problems with multiple instances
        return;  # sp_calc dropped out for some reason, eg no valid calculations.
    }

    if ($overwrite) {  #  clear out the old ref and reinstate the user specified name
        say '[SPATIAL] Replacing old analysis with new version';
        my $old_ref = $self->{output_ref};
        $self->{basedata_ref}->delete_output(output => $old_ref);
        $self->{project}->delete_output($old_ref);
        #  rename the temp file in the basedata
        $self->{basedata_ref}->rename_output (
            output   => $output_ref,
            new_name => $self->{output_name},
        );
        delete $self->{stats};
    }

    $self->{output_ref} = $output_ref;
    $self->{project}->add_output($self->{basedata_ref}, $output_ref);

    $self->register_in_outputs_model($output_ref, $self);
    $self->{project}->update_indices_rows($output_ref);

    my $isnew = 0;
    if (!$self->{existing}) {
        $isnew = 1;
        $self->{existing} = 1;
    }

    my $response = Biodiverse::GUI::YesNoCancel->run({
        title  => 'display?',
        header => 'display results?',
    });
    if ($response eq 'yes') {
        # If just ran a new analysis, pull up the pane
        $self->set_pane(0.01, 'vpaneSpatial');

        # Update output display if we are a new result
        # or grid is not defined yet (this can happen)
        if ($new_result || !defined $self->{grid} || !blessed($self->{grid})) {
            eval {$self->init_grid()};
            if ($EVAL_ERROR) {
                $self->{gui}->report_error ($EVAL_ERROR);
            }
        }
        #  else reuse the grid and just reset the basestruct
        elsif (defined $output_ref) {
            $self->{grid}->set_base_struct($output_ref);
        }
        $self->get_xmlpage_object('hbox_spatial_tab_bottom')->show;
        $self->get_xmlpage_object('toolbarSpatial')->show;
        $self->update_lists_combo; # will display first analysis as a side-effect...
        #$self->setup_dendrogram;   # completely refresh the dendrogram
        $self->update_dendrogram_combo;
        $self->on_selected_phylogeny_changed;  # update the tree plot
        $self->init_branch_colouring_menu (refresh => 1);
    }

    #  make sure the grid is sensitive again
    $self->{initialising_grid} = 0;

    $self->update_export_menu;
    $self->update_tree_menu;

    $self->{project}->set_dirty;

    return;
}

##################################################
# Misc dialog operations
##################################################

# Called by grid when user hovers over a cell
# and when mouse leaves a cell (element undef)
sub on_grid_hover {
    my $self    = shift;
    my $element = shift;

    #  drop out if we are initialising, otherwise we trigger events on incomplete data
    return if $self->{initialising_grid};

    my $output_ref = $self->{output_ref};
    my $text = $self->get_grid_text_pfx;

    my $bd_ref = $output_ref->get_param ('BASEDATA_REF') || $output_ref;

    if (defined $element) {
        no warnings 'uninitialized';  #  sometimes the selected_list or analysis is undefined
        # Update the Value label
        my $elts = $output_ref->get_element_hash();

        my $val = $elts->{$element}{ $self->{selected_list} }{$self->{selected_index}};

        $text .= sprintf '<b>%s, Output - %s: </b>',
            $element,
            $self->{selected_index};
        $text .= defined $val
            ? $self->format_number_for_display (number => $val)
            : 'value is undefined';

        $self->get_xmlpage_object('lblOutput')->set_markup($text);

        # Mark out neighbours
        my $neighbours = $self->{hover_neighbours};

        #  take advantage of the caching now in use - let sp_calc handle these calcs
        my @nbr_list;
        $nbr_list[0] = $output_ref->get_list_values (
            element => $element,
            list    => '_NBR_SET1',
        );
        $nbr_list[1] = $output_ref->get_list_values (
            element => $element,
            list    => '_NBR_SET2',
        );

        my $nbrs_inner = $nbr_list[0] || [];
        my $nbrs_outer = $nbr_list[1] || [];  #  an empty list by default

        my (%nbrs_hash_inner, %nbrs_hash_outer);

        if ($neighbours eq 'Set1' || $neighbours eq 'Both') {
            @nbrs_hash_inner{ @$nbrs_inner } = undef;
            $self->{grid}->mark_if_exists(\%nbrs_hash_inner, 'circle');
        }
        if ($neighbours eq 'Set2' || $neighbours eq 'Both') {
            @nbrs_hash_outer{ @$nbrs_outer } = undef;
            $self->{grid}->mark_if_exists(\%nbrs_hash_outer, 'minus');
        }
        #if ($neighbours eq 'Off') {  #  highlight the labels from the hovered group on the tree
        #    $nbrs_hash_inner{$element} = 1;
        #}

        # dendrogram highlighting from labels.pm
        $self->{dendrogram}->clear_highlights();

        #  does this even trigger now?
        my $group = $element; # is this the same?
        return if ! defined $group;

        # get labels in the group
        my $bd = $bd_ref;
        my (%labels1, %labels2);

        foreach my $nbr_grp (@$nbrs_inner) {
            my $this_labels = $bd->get_labels_in_group_as_hash_aa ($nbr_grp);
            @labels1{keys %$this_labels} = values %$this_labels;
        }
        foreach my $nbr_grp (@$nbrs_outer) {
            my $this_labels = $bd->get_labels_in_group_as_hash_aa ($nbr_grp);
            @labels2{keys %$this_labels} = values %$this_labels;
        }

        $self->highlight_paths_on_dendrogram ([\%labels1, \%labels2], $group);
    }
    else {
        $self->{grid}->mark_if_exists({}, 'circle');
        $self->{grid}->mark_if_exists({}, 'minus');

        $self->{dendrogram}->clear_highlights();
    }

    return;
}


#  #1F78B4 = blue
#  #8DA0CB = mid-blue
#  #2166ac = a brighter blue
#  #4393c3 = a light brighter blue
#  #33a02c = mid green
#  #E31A1C = red
#  #000000 = black
#  #00FFFC = cyan(ish)
my @dendro_highlight_branch_colours
  = map {Gtk2::Gdk::Color->parse($_)} ('#1F78B4', '#E31A1C', '#000000');

sub highlight_paths_on_dendrogram {
    my ($self, $hashrefs, $group) = @_;

    if (my $sources = $self->{current_branch_colouring_source}) {
        my ($ref, $listname) = @$sources;
        $self->colour_branches_on_dendrogram (
            list_name  => $listname,
            output_ref => $ref,
            group      => $group,
        );
        return;
    }

    $self->{dendrogram}->get_legend->hide;
    
    my $tree = $self->get_current_tree;

    # Highlight the branches in the groups on the tree.
    # Last colour is when branch is in both groups.
    #my (%coloured_branch, %done);
    my %done;
    my $dendrogram = $self->{dendrogram};

    foreach my $idx (0, 1) {
        my $alt_idx = $idx ? 0 : 1;
        my $href    = $hashrefs->[$idx];
        my $colour  = $dendro_highlight_branch_colours[$idx];
        my $node_ref;
      LABEL:
        foreach my $label (keys %$href) {
            # Might not match some or all nodes
            my $success = eval {
                $node_ref = $tree->get_node_ref_aa ($label);
            };
            next LABEL if !$success;
            # set path to highlighted colour
          NODE:
            while ($node_ref) {
                my $node_name = $node_ref->get_name;
                last NODE if ($done{$node_name}[$idx] // 0) > 1;

                my $colour_ref = $done{$node_name}[$alt_idx]
                  ? $dendro_highlight_branch_colours[-1]
                  : $colour;

                $dendrogram->highlight_node ($node_ref, $colour_ref);
                $dendrogram->set_node_colour(
                    colour_ref => $colour_ref,
                    node_name  => $node_name,
                );

                $done{$node_name}[$idx]++;

                $node_ref = $node_ref->get_parent;
            }
        }
    }

    return;
}

sub colour_branches_on_dendrogram {
    my $self = shift;
    my %args = @_;
    
    my $tree = $self->get_current_tree;

    return if !$tree;

    my $list_name  = $args{list_name};
    my $dendrogram = $self->{dendrogram};

    my $output_ref = $args{output_ref};
    $list_name =~ s{\s+<i>.+$}{};

    my $legend = $dendrogram->get_legend;
    $legend->set_colour_mode_from_list_and_index (
        list  => $list_name,
        index => '',
    );

    $legend->set_log_mode($self->{use_tree_log_scale});
    $legend->set_invert_colours ($self->{tree_invert_colours});

    my $listref = $output_ref->get_list_ref (
        list    => $list_name,
        element => $args{group},
    );
    
    my $minmax
      = $self->get_index_min_max_values_across_full_list ($list_name, $output_ref);
    my ($min, $max) = @$minmax;  #  should not need to pass this
    $legend->set_min_max ($min, $max);

    #  currently does not handle ratio or CANAPE - these do not yet apply for tree branches
    my @minmax_args = ($min, $max);
    my $colour_method = $legend->get_colour_method;

    my $checkbox_show_tree_legend = $self->{checkbox_show_tree_legend};
    if ($checkbox_show_tree_legend->get_active) {
        $dendrogram->update_legend;  #  need dendrogram to pass on coords
        $legend->show;
    }

    my %done;

  LABEL:
    foreach my $label (keys %$listref) {
        next LABEL if $done{$label};
        
        # Might not match some or all nodes
        next LABEL if !$tree->exists_node(name => $label);

        my $node_ref = $tree->get_node_ref_aa ($label);
        my $colour_ref;

        #  Colour ourselves, and also work our way up the tree
        #  and do our ancestors.
        #  This ensures ancestors get the default colour
        #  if they are not in the list or are undef. 
      NODE:
        while ($node_ref) {
            my $node_name = $node_ref->get_name;
            last NODE if $done{$node_name};

            my $val = $listref->{$node_name};
            $colour_ref
                = defined $val
                ? $legend->$colour_method ($val, @minmax_args)
                : COLOUR_BLACK;

            $dendrogram->highlight_node ($node_ref, $colour_ref);
            $dendrogram->set_node_colour(
                colour_ref => $colour_ref,
                node_name  => $node_name,
            );

            $done{$node_name}++;

            $node_ref = $node_ref->get_parent;
        }
    }

}

sub on_end_grid_hover {
    my $self = shift;
    my $dendrogram = $self->{dendrogram}
      // return;

    $dendrogram->clear_highlights ($dendrogram->get_default_line_colour);
}

sub get_trees_are_available_to_plot {
    my $self = shift;

    my $count = $self->{project}->get_available_phylogeny_count;

    if ($self->{output_ref} && $self->{output_ref}->can('get_embedded_tree')) {
        if ($self->{output_ref}->get_embedded_tree) {
            $count++;
        }
    }

    return !!$count;
}

sub get_current_tree {
    my $self = shift;

    return if !$self->{output_ref};

    # check combo box to choose if project phylogeny or tree used in spatial analysis
    my $tree_method = $self->get_xmlpage_object('comboTreeSelect')->get_active_text();
    $tree_method //= 'none';

    my $tree_frame = $self->get_xmlpage_object ('frame_spatial_tree_plot');

    if ($tree_method eq 'hide panel') {
        $tree_frame->hide;
        return;
    }
    else {
        $tree_frame->show;
    }

    return if $tree_method eq 'none';

    # phylogenies
    if ($tree_method eq 'analysis') {
        # get tree from spatial analysis, if possible
        return if !$self->{output_ref}->can('get_embedded_tree');
        return $self->{output_ref}->get_embedded_tree;
    }

    # get tree from project
    return $self->{project}->get_selected_phylogeny;
}

# Keep name in sync with the tab label
# and do a rename if the object exists
sub on_name_changed {
    my $self = shift;

    my $xml_page = $self->{xmlPage};
    my $name = $xml_page->get_object('txtSpatialName')->get_text();

    my $label_widget = $self->{xmlLabel}->get_object('lblSpatialName');
    $label_widget->set_text($name);

    my $tab_menu_label = $self->{tab_menu_label};
    $tab_menu_label->set_text($name);

    my $param_widget
        = $xml_page->get_object('lbl_parameter_spatial_name');
    $param_widget->set_markup("<b>Name</b>");

    my $bd = $self->{basedata_ref};

    my $name_in_use = eval {$bd->get_spatial_output_ref (name => $name)};

    #  make things go red
    if ($name_in_use) {
        #  colour the label red if the list exists
        my $label = $name;
        my $span_leader = '<span foreground="red">';
        my $span_ender  = ' <b>Name exists</b></span>';

        $label =  $span_leader . $label . $span_ender;
        $label_widget->set_markup ($label);

        $param_widget->set_markup ("$span_leader <b>Name </b>$span_ender");

        return;
    }

    # rename
    if ($self->{existing}) {
        my $object = $self->{output_ref};
        eval {
            $bd->rename_output(
                output   => $object,
                new_name => $name
            );
        };
        if ($EVAL_ERROR) {
            $self->{gui}->report_error ($EVAL_ERROR);
            return;
        }

        $self->{project}->update_output_name( $object );
        $self->{output_name} = $name;
    }

    return 1;
}


# Called by output tab to make us show an analysis result
sub show_analysis {
    my $self = shift;
    my $name = shift;

    # Reinitialising is a cheap way of showing
    # the SPATIAL_RESULTS list (the default), and
    # selecting what we want

    $self->{selected_index} = $name;
    $self->update_lists_combo();
    $self->update_output_indices_combo();
    $self->update_dendrogram_combo();

    return;
}

sub on_active_list_changed {
    my $self = shift;
    my $combo = shift;

    my $iter = $combo->get_active_iter() || return;
    my ($list) = $self->{output_lists_model}->get($iter, 0);

    $self->{selected_list} = $list;
    $self->update_output_indices_combo();
    #$self->update_output_indices_menu();

    $self->{output_ref}->set_cached_value(LAST_SELECTED_LIST => $list);

    return;
}

sub update_output_indices_combo {
    my $self = shift;

    # Make the model
    $self->{output_indices_model} = $self->make_output_indices_model();
    my $combo = $self->get_xmlpage_object('comboIndices');
    $combo->set_model($self->{output_indices_model});

    # Select the previous analysis (or the first one)
    my $iter = $self->{output_indices_model}->get_iter_first();
    my $selected = $iter;

    BY_ITER:
    while ($iter) {
        my ($analysis) = $self->{output_indices_model}->get($iter, 0);
        if ($self->{selected_index} && ($analysis eq $self->{selected_index}) ) {
            $selected = $iter;
            last BY_ITER; # break loop
        }
        $iter = $self->{output_indices_model}->iter_next($iter);
    }

    if ($selected) {
        $combo->set_active_iter($selected);
    }
    $self->on_active_index_changed($combo);

    return;
}


sub on_output_index_toggled {
    my ($self, $menu_item) = @_;

    # Just got the signal for the deselected option. Wait for signal for
    # selected one.
    if (!$menu_item->get_active()) {
        return;
    }

    # Got signal for newly selected option.
    my $index = $menu_item->get_label();
    $index =~ s/__/_/g;

    $self->{selected_index} = $index;

    # Process
    $self->on_active_index_changed();
}

sub init_output_indices_combo {
    my $self = shift;

    my $combo = $self->get_xmlpage_object('comboIndices');
    my $renderer = Gtk2::CellRendererText->new();
    $combo->pack_start($renderer, 1);
    $combo->add_attribute($renderer, text => 0);

    # Only do this if we aren't a new spatial analysis...
    if ($self->{existing}) {
        $self->update_output_indices_combo();
    }

    return;
}

#  should be called on_active_index_changed, but many such occurrences need to be edited
sub on_active_index_changed {
    my $self = shift;
    my $combo = shift
        ||  $self->get_xmlpage_object('comboIndices');

    my $iter = $combo->get_active_iter() || return;
    my ($index) = $self->{output_indices_model}->get($iter, 0);
    $self->{selected_index} = $index;  #  should be called calculation

    $self->set_plot_min_max_values;

    $self->recolour();

    return;
}

#  bad name - we want all values across all lists of name $listname across all elements
sub get_index_min_max_values_across_full_list {
    my ($self, $list_name, $output_ref) = @_;

    $output_ref //= $self->{output_ref};

    use List::MoreUtils qw /minmax/;
    my $stats = $self->{list_minmax_across_all_elements}{$output_ref}{$list_name};
    
    return $stats if $stats;

    my @minmax;
    foreach my $element ($output_ref->get_element_list) {
        my $list_ref = $output_ref->get_list_ref (
            element    => $element,
            list       => $list_name,
            autovivify => 0,
        );
        next if !defined $list_ref;
        next if !scalar keys %$list_ref;

        @minmax = minmax (grep {defined $_}  values %$list_ref, @minmax);
    }
    
    $stats = \@minmax;

    #  store it
    $self->{list_minmax_across_all_elements}{$output_ref}{$list_name} = $stats;

    return $stats;
}

sub set_plot_min_max_values {
    my $self = shift;

    my $output_ref = $self->{output_ref};

    my $list  = $self->{selected_list};
    my $index = $self->{selected_index};

    my $stats = $self->{stats}{$list}{$index};

    if (not $stats) {
        $stats = $output_ref->get_list_value_stats (
            list  => $list,
            index => $index,
        );
        $self->{stats}{$list}{$index} = $stats;  #  store it
    }

    $self->{plot_max_value} = $stats->{$self->{PLOT_STAT_MAX} || 'MAX'};
    $self->{plot_min_value} = $stats->{$self->{PLOT_STAT_MIN} || 'MIN'};

    $self->set_legend_ltgt_flags ($stats);

    return;
}


sub on_menu_stretch_changed {
    my ($self, $menu_item) = @_;

    # Just got the signal for the deselected option. Wait for signal for
    # selected one.
    return if !$menu_item->get_active();

    my $sel = $menu_item->get_label();

    my ($min, $max) = split (/-/, uc $sel);

    my %stretch_codes = $self->get_display_stretch_codes;

    $self->{PLOT_STAT_MAX} = $stretch_codes{$max} || $max;
    $self->{PLOT_STAT_MIN} = $stretch_codes{$min} || $min;

    $self->on_active_index_changed;

    return;
}

sub on_stretch_changed {
    return;

    my $self = shift;
    my $sel = $self->get_xmlpage_object('comboSpatialStretch')->get_active_text();

    my ($min, $max) = split (/-/, uc $sel);

    my %stretch_codes = $self->get_display_stretch_codes;

    $self->{PLOT_STAT_MAX} = $stretch_codes{$max} || $max;
    $self->{PLOT_STAT_MIN} = $stretch_codes{$min} || $min;

    $self->on_active_index_changed;

    return;
}

sub recolour {
    my $self = shift;
    my ($max, $min) = ($self->{plot_max_value} || 0, $self->{plot_min_value} || 0);

    # callback function to get colour of each element
    my $grid = $self->{grid};
    return if not defined $grid;  #  if no grid then no need to colour.

    my $output_ref    = $self->{output_ref};
    my $elements_hash = $output_ref->get_element_hash;
    my $list  = $self->{selected_list};
    my $index = $self->{selected_index};

    return if !defined $index;

    my $colour_none = $self->get_undef_cell_colour // COLOUR_WHITE;
    my $colour_cache
      = $output_ref->get_cached_value_dor_set_default_aa (
        GUI_CELL_COLOURS => {},
    );
    #  warm up the cache.  
    #  we otherwise get hard crashes if we try
    #  to autoviv the cache hash in the callback
    #say 'WARNING - CLEARING CACHE FOR DEBUG';
    #delete @{$colour_cache}{keys %$colour_cache};  #  temp for debug
    my $ccache = $colour_cache->{$list}{$index} //= {};

    my $legend = $grid->get_legend;

    $legend->set_colour_mode_from_list_and_index (
        list  => $list,
        index => $index,
    );
    my $colour_method = $legend->get_colour_method;

    my $colour_func = sub {
        my $elt = shift // return;

        my $colour;
        if (!$output_ref->group_passed_def_query_aa($elt)) {
            $colour = $self->get_excluded_cell_colour;
        }
        else {
            no autovivification;
            #  should use a method here
            my $val = $elements_hash->{$elt}{$list}{$index};
            $colour
              = defined $val
              ? $legend->$colour_method ($val, $min, $max)
              : $colour_none;
        }
        
        $ccache->{$elt} = $colour->to_string;

        return $colour;
    };
    
    #my $defq_callback = sub {
    #    my $elt = shift // return;
    #    !$output_ref->group_passed_def_query(group => $elt);
    #};

    $self->show_legend;

    $grid->colour($colour_func);
    #$grid->hide_some_cells($defq_callback);
    $grid->set_legend_min_max($min, $max);

    $self->{grid}->update_legend;
    
    return;
}

sub hide_legend {
    my $self = shift;
    $self->{grid}->hide_legend;
}

sub show_legend {
    my $self = shift;
    $self->{grid}->show_legend;
}

sub on_colours_changed {
    return;

    my $self = shift;
    my $colours = $self->get_xmlpage_object('comboColours')->get_active_text();
    $self->{grid}->set_legend_mode($colours);
    $self->recolour();

    return;
}

sub on_menu_colours_changed {
    my $args = shift;
    my ($self, $type) = @$args;

    $self->{grid}->set_legend_mode($type);
    $self->recolour();

    return;
}

sub on_menu_neighbours_changed {
    my ($self, $menu_item) = @_;

    # Just got the signal for the deselected option. Wait for signal for
    # selected one.
    return if !$menu_item->get_active();

    my $sel = $menu_item->get_label();

    $self->{hover_neighbours} = $sel;

    # Turn off markings if deselected
    if ($sel eq 'Set1' || $sel eq 'Off') {
        $self->{grid}->mark_if_exists({}, 'minus');
    }
    if ($sel eq 'Set2' || $sel eq 'Off') {
        $self->{grid}->mark_if_exists({}, 'circle');
    }

    return;
}

#  redundant now
sub __on_neighbours_changed {
    my $self = shift;
    my $sel = $self->get_xmlpage_object('comboNeighbours')->get_active_text();
    $self->{hover_neighbours} = $sel;

    # Turn off markings if deselected
    if ($sel eq 'Set1' || $sel eq 'Off') {
        $self->{grid}->mark_if_exists({}, 'minus');
    }
    if ($sel eq 'Set2' || $sel eq 'Off') {
        $self->{grid}->mark_if_exists({}, 'circle');
    }

    ##  this is a dirty bodge for testing purposes
    #if ($sel =~ /colour/) {
    #    $self->{grid}->set_cell_outline_colour;
    #}

    return;
}

#  should be called onSatSet
sub on_colour_set {
    return;

    my $self = shift;
    my $button = shift;

    my $combo_colours_hue_choice = 1;

    my $widget = $self->get_xmlpage_object('comboColours');

    #  a bodge to set the active colour mode to Hue
    my $active = $widget->get_active;

    $widget->set_active($combo_colours_hue_choice);
    $self->{grid}->set_legend_hue($button->get_color());
    $self->recolour();

    return;
}

sub on_overlays {
    my $self = shift;
    my $button = shift;

    Biodiverse::GUI::Overlays::show_dialog( $self->{grid} );

    return;
}

sub on_add_param {
    my $self = shift;
    my $button = shift; # the "add param" button

    my $table = $self->get_xmlpage_object('tblParams');

    # Add an extra row
    my ($rows) = $table->get('n-rows');
    print "currently has $rows rows. ";
    $rows++;
    $table->set('n-rows' => $rows);
    print "now has $rows rows\n";

    # Move the button to the last row
    $table->remove($button);
    $table->attach($button, 0, 1, $rows, $rows + 1, [], [], 0, 0);

    # Make a combobox and a label to set the parameter
    my $combo = Gtk2::ComboBox->new_text;
    my $entry = Gtk2::Entry->new;

    $table->attach($combo, 0, 1, $rows - 1, $rows, 'fill', [], 0, 0);
    $table->attach($entry, 1, 2, $rows - 1, $rows, 'fill', [], 0, 0);

    $combo->show; $entry->show;

    # Add the optional parameters
    $combo->prepend_text("..these are not yet heeded..");
    $combo->prepend_text("Use Matrix");
    $combo->prepend_text("Max Richness");

    return;
}

sub get_options_menu {
    my $self = shift;

    my $menu = Gtk2::Menu->new();

    $menu->append(Gtk2::MenuItem->new('_Cut'));
    $menu->append(Gtk2::MenuItem->new('C_opy'));
    $menu->append(Gtk2::MenuItem->new('_Paste'));

    $menu->show_all();

    return $menu;
}

####
# TODO: This whole section needs to be deduplicated between Labels.pm
####
sub choose_tool {
    my $self = shift;
    my ($tool, ) = @_;

    my $old_tool = $self->{tool};

    if ($old_tool) {
        $self->{ignore_tool_click} = 1;
        my $widget = $self->get_xmlpage_object("btn${old_tool}ToolSP");
        $widget->set_active(0);
        my $new_widget = $self->get_xmlpage_object("btn${tool}ToolSP");
        $new_widget->set_active(1);
        $self->{ignore_tool_click} = 0;
    }

    $self->{tool} = $tool;

    if ($self->{grid} && blessed $self->{grid}) {  # might not be initialised yet
        $self->{grid}{drag_mode} = $self->{drag_modes}{$tool};
    }
    $self->{dendrogram}{drag_mode} = $self->{drag_modes}{$tool};

    $self->set_display_cursors ($tool);
}

#  cargo culted from SpatialParams.pm under the assumption that it will diverge over time
sub run_options_dialogue {
    my $self = shift;

    my $dlg = Gtk2::Dialog->new (
        'Spatial conditions options',
        undef,
        'modal',
        'gtk-cancel' => 'cancel',
        'gtk-ok' => 'ok',
    );

    my $options = $self->{options};
    if (!$options) {
        my ($ignore_spatial_index, $no_recycling);
        if (my $output_ref = $self->{output_ref}) {
            no autovivification;
            my ($p_key, $analysis_args) = $output_ref->get_analysis_args_from_object (
                object => $output_ref,
            );
            $ignore_spatial_index = $analysis_args->{ignore_spatial_index};
            $no_recycling = $analysis_args->{no_recycling};
        }
        $self->{options} = {
            ignore_spatial_index => $ignore_spatial_index,
            no_recycling         => $no_recycling,
        };
        $options = $self->{options};
    }


    my $table = Gtk2::Table->new(2, 2);
    $table->set_row_spacings(5);
    $table->set_col_spacings(20);

    my @tb_props = (['expand', 'fill'], 'shrink', 0, 0);
    my $tip_text;

    my $row = 0;
    my $sp_index_label    = Gtk2::Label->new ('Ignore spatial index?');
    my $sp_index_checkbox = Gtk2::CheckButton->new;
    $sp_index_checkbox->set_active ($options->{ignore_spatial_index});
    $table->attach($sp_index_label,    0, 1, $row, $row+1, @tb_props);
    $table->attach($sp_index_checkbox, 1, 2, $row, $row+1, @tb_props);
    $tip_text = 'Set this to on if the spatial conditions do not work properly '
              . "when the BaseData has a spatial index set.\n"
              . 'This can also be set on a per-condition basis via the conditions properties';
    foreach my $widget ($sp_index_label, $sp_index_checkbox) {
        $widget->set_has_tooltip(1);
        $widget->set_tooltip_text ($tip_text);
    }

    $row++;
    my $recyc_label = Gtk2::Label->new ('Turn off recycling?');
    my $recyc_checkbox = Gtk2::CheckButton->new;
    $recyc_checkbox->set_active ($options->{no_recycling});
    $table->attach($recyc_label,    0, 1, $row, $row+1, @tb_props);
    $table->attach($recyc_checkbox, 1, 2, $row, $row+1, @tb_props);
    $tip_text = 'Biodiverse tries to detect cases where it can recycle neighour '
              . "sets and spatial results, and this can sometimes not work.\n"
              . "Set this to on to stop Biodiverse checking for such cases.\n"
              . 'This can also be set on a per-condition basis via the conditions properties';
    foreach my $widget ($recyc_label, $recyc_checkbox) {
        $widget->set_has_tooltip(1);
        $widget->set_tooltip_text ($tip_text);
    }

    my $vbox = $dlg->get_content_area;
    $vbox->pack_start ($table, 0, 0, 0);
    $dlg->show_all;

    my $result = $dlg->run;

    if (lc($result) eq 'ok') {
        $options->{ignore_spatial_index} = $sp_index_checkbox->get_active;
        $options->{no_recycling}         = $recyc_checkbox->get_active;
    }

    $dlg->destroy;
    return;
}

sub get_options {
    my $self = shift;

    my $options = $self->{options} // {};

    return wantarray ? %$options : $options;
}

sub on_show_tree_legend_changed {
    my ($self, $menu_item) = @_;
    
    my $legend = $self->{dendrogram}->get_legend;
    return if !$legend;

    my $check = $menu_item->get_active;

    my $menu = $self->{branch_colouring_menu};
    return if !$menu;

    #  no legend for turnover
    my $aref = $self->{current_branch_colouring_source};
    if (!defined $aref) {
        $check = 0;
    }
    $check &&= !$self->{no_dendro_legend_for}{$aref->[0] // ''};

    $legend->set_visible($check);
}


#  Too similar to on_colour_mode_changed
#  Need to refactor the two
sub on_tree_colour_mode_changed {
    my ($self, $menu_item) = @_;
    
    my $legend = $self->{dendrogram}->get_legend;

    if ($menu_item) {
        # Just got the signal for the deselected option.
        # Wait for signal for selected one.
        return if !$menu_item->get_active();

        my $mode = $menu_item->get_label();
    
        if ($mode eq 'Sat...') {
            $mode = 'Sat';

            # Pop up dialog for choosing the hue to use in saturation mode
            my $colour_dialog = Gtk2::ColorSelectionDialog->new('Pick Hue');
            my $colour_select = $colour_dialog->get_color_selection();
            $colour_dialog->show_all();
            my $response = $colour_dialog->run;
            if ($response eq 'ok') {
                my $hue = $colour_select->get_current_color();
                $legend->set_hue($hue);
            }
            $colour_dialog->destroy();
        }
        
        $legend->set_mode($mode);
    }

    #  legend should be able to update itself,
    #  but currently we need to do it through the
    #  dendrogram or it gets zero size and is
    #  not visible
    $self->{dendrogram}->update_legend;

    return;
}


#  methods aren't inherited when called as GTK callbacks
#  so we have to manually inherit them using SUPER::
our $AUTOLOAD;

sub AUTOLOAD {
    my $self = shift;
    my $type = ref($self)
                or croak "$self is not an object\n";

    my $method = $AUTOLOAD;
    $method =~ s/.*://;   # strip fully-qualified portion

    $method = "SUPER::" . $method;
    #print $method, "\n";
    return $self->$method(@_);
}

sub DESTROY {}  #  let the system handle destruction - need this for AUTOLOADER


1;
