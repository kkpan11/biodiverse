package Biodiverse::GUI::Export;

#
# Generic export dialog, with dynamically generated parameters table
#

use strict;
use warnings;

use English ( -no_match_vars );

use Glib;
use Gtk2;
use Cwd;

use List::MoreUtils qw /any none/;
use Path::Tiny qw /path/;

our $VERSION = '4.99_002';

use Biodiverse::GUI::GUIManager;
use Biodiverse::GUI::ParametersTable;
use Biodiverse::GUI::YesNoCancel;

use 5.010;

sub Run {
    my ($object, %args) = @_;
    
    my $selected_format = $args{selected_format} || '';
    
    #  sometimes we get called on non-objects,
    #  eg if nothing is highlighted
    return if ! defined $object;

    my $gui = Biodiverse::GUI::GUIManager->instance;

    #  stop keyboard events being applied to any open tabs
    my $snooper_status = $gui->keyboard_snooper_active;
    $gui->activate_keyboard_snooper (0);

    # Get the Parameters metadata
    my $metadata = $object->get_metadata (sub => 'export');

    ###################
    # get the selected format

    my $format_choices = $metadata->get_format_choices;
    my $format_choice_array = $format_choices->[0]{choices};

    if (none {$_ eq $selected_format} @$format_choice_array) {
        #  get user preference if none passed as an arg
        
        my $dlgxml = Gtk2::Builder->new();
        $dlgxml->add_from_file($gui->get_gtk_ui_file('dlgImportParameters.ui'));
        my $format_dlg = $dlgxml->get_object('dlgImportParameters');

        $format_dlg->set_transient_for( $gui->get_object('wndMain') );
        $format_dlg->set_title ('Export parameters');

        # Build widgets for parameters
        my $format_table = $dlgxml->get_object('tableImportParameters');

        # (passing $dlgxml because generateFile uses existing widget on the dialog)
        my $parameters_table = Biodiverse::GUI::ParametersTable->new;
        my $format_extractors
            = $parameters_table->fill(
                $format_choices,
                $format_table,
                $dlgxml,
        );

        # Show the dialog
        $format_dlg->show_all();

      RUN_FORMAT_DIALOG:
        my $format_response = $format_dlg->run();

        if ($format_response ne 'ok') {
            $format_dlg->destroy;
            $gui->activate_keyboard_snooper ($snooper_status);
            return;
        }

        my $formats
          = $parameters_table->extract($format_extractors);

        $selected_format = $formats->[1];

        $format_dlg->destroy;
    }


    my $params = $metadata->get_parameters_for_format(format => $selected_format);

  RUN_DIALOG:
    my $results = choose_file_location_dialog(
        gui    => $gui, 
        params => $params,
        selected_format => $selected_format,
    );

    if (!$results->{success}) {
        $gui->activate_keyboard_snooper($snooper_status);
        return;
    }

    my $chooser = $results->{chooser};
    my $parameters_table = $results->{param_table};
    my $extractors = $results->{extractors};
    my $dlg = $results->{dlg};
    
    # Export!
    my $extracted_params = $parameters_table->extract($extractors);
    my $filename = $chooser->get_filename;
    #  normalise the file name
    $filename = path($filename)->stringify;

    my $writefile = 'yes';
    while (-e $filename) {
        $writefile = Biodiverse::GUI::YesNoCancel->run({
            header => "Overwrite file $filename?"
        });
        last if $writefile ne 'no';
        #  get a new file name
        $dlg->run;
        $filename  = $chooser->get_filename;
        $filename  = path ($filename)->stringify;
        $writefile = 'yes';
    }

    if ($writefile eq 'yes') {
        eval {
            $object->export(
                format         => $selected_format,
                file           => $filename,
                @$extracted_params,
            )
        };
        if ($EVAL_ERROR) {
            $gui->activate_keyboard_snooper (1);
            $gui->report_error ($EVAL_ERROR);
        }
    }

    $dlg->destroy;
    $gui->activate_keyboard_snooper ($snooper_status);

    return;
}


sub choose_file_location_dialog {
    my %args = @_;
    my $gui = $args{gui};
    my $params = $args{params};
    my $selected_format = $args{selected_format};

    
    #####################
    #  get the params for the selected format
    my $dlgxml = Gtk2::Builder->new();
    $dlgxml->add_from_file($gui->get_gtk_ui_file('dlgExport.ui'));

    my $dlg = $dlgxml->get_object('dlgExport');
    $dlg->set_transient_for( $gui->get_object('wndMain') );
    $dlg->set_title("Export format: $selected_format");
    $dlg->set_modal(1);

    my $chooser = $dlgxml->get_object('filechooser');
    $chooser->set_current_folder_uri(getcwd());
    # does not stop the keyboard events on open tabs
    #$chooser->signal_connect ('button-press-event' => sub {1});

    # Build widgets for parameters
    my $table = $dlgxml->get_object('tableParameters');
    # (passing $dlgxml because generateFile uses existing widget on the dialog)
    my $parameters_table = Biodiverse::GUI::ParametersTable->new;
    my $extractors
        = $parameters_table->fill(
            $params,
            $table,
            $dlgxml
    );

    # Show the dialog
    $dlg->show_all();


    my $response = $dlg->run();

    if ($response ne 'ok') {
        $dlg->destroy;
        $gui->activate_keyboard_snooper (1);
        return {success => 0};
    }

    my $result = {
        success => 1,
        chooser => $chooser,
        param_table => $parameters_table,
        extractors => $extractors,
        dlg => $dlg,
    };

    return $result;
}

1;
