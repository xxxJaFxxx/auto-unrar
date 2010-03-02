# ToDo
# mtime pro adresare
# check free space
# unrar and duplicate names
# unrar to temp directory - go back if error
# * compare fname and fname.1 content, remove .1 if same
# refactore, better configuration, help, ...
# merge changes to Archive::Rar
# password protected archives support
# backup old version of done_list files, remove backup after normal end
# add run_type as dynamic conf name
# after failed - save info about files - try if changed
# full paths of files in archive
# refactor to Perl package

use strict;
use warnings;

use Carp qw(carp croak verbose);
use FindBin qw($RealBin);

use File::Spec::Functions qw/:ALL splitpath/;
use File::Copy;
use File::stat;

use Storable;
use Data::Dumper;


use lib 'lib';
use App::KeyPress;
use Archive::Rar;


my $run_type = $ARGV[0];
if ( ! $run_type || $run_type !~  /^(test|final)$/i ) {
    print "Usage:\n";
    print "  perl unrar2.pl test\n";
    print "  perl unrar2.pl final\n";
}

my $ver = $ARGV[1];
$ver = 2 unless defined $ver;

my $only_dconf_name = $ARGV[2];

print "Run type: $run_type\n" if $ver >= 2;


my $keypress_obj = App::KeyPress->new(
    $ver,
    0 # $debug
);


sub my_croak {
    my ( $err_msg ) = @_;
    $keypress_obj->cleanup_before_exit();
    croak $err_msg;
}



my $dirs_conf = [
];


# devel
if ( $run_type ne 'final' ) {
    $dirs_conf = [
        {
            name => 'test',
            src_dir => '/mnt/pole2/scripts/auto-unrar-test/in',
            dest_dir => '/mnt/pole2/scripts/auto-unrar-test/out',
            done_list => '/mnt/pole2/scripts/auto-unrar-test/test-unrar.db',
            exclude_list => '/mnt/pole2/scripts/auto-unrar-test/rsync-exclude.txt',
            done_list_deep => 1,
            recursive => 1,
            remove_done => 1,
            move_non_rars => 1,
            min_dir_mtime => 60, # 1*60*60, # seconds
        },
    ];
}


sub debug_suffix {
    my ( $msg, $caller_back ) = @_;
    $caller_back = 1 unless defined $caller_back;

    $msg =~ s/[\n\s]+$//;

    my $has_new_line = 0;
    $has_new_line = 1 if $msg =~ /\n/;

    my $caller_line = (caller 0+$caller_back)[2];
    my $caller_sub = (caller 1+$caller_back)[3];

    $msg .= " ";
    $msg .= "(" unless $has_new_line;
    $msg .= "$caller_sub " if $caller_sub;
    $msg .= "on line $caller_line";
    $msg .= ')' unless $has_new_line;
    $msg .= ".\n";
    $msg .= "\n" if $has_new_line;
    return $msg;
}


sub dumper {
    my ( $prefix_text, $data, $caller_back ) = @_;

    my $ot = '';
    if ( (not defined $data) && $prefix_text =~ /^\n$/ ) {
        $ot .= $prefix_text;
        return 1;
    }

    $caller_back = 0 unless defined $caller_back;
    if ( defined $prefix_text ) {
        $prefix_text .= ' ';
    } else {
        $caller_back = 0;
        $prefix_text = '';
    }

    $ot = $prefix_text;
    if ( defined $data ) {
        local $Data::Dumper::Indent = 1;
        local $Data::Dumper::Purity = 1;
        local $Data::Dumper::Terse = 1;
        local $Data::Dumper::Sortkeys = 1;
        $ot .= Data::Dumper->Dump( [ $data ], [] );
    }

    if ( $caller_back >= 0 ) {
        $ot = debug_suffix( $ot, $caller_back+1 );
    }

    print $ot;
    return 1;
}


sub load_dir_content {
    my ( $dir_name ) = @_;

    my $dir_h;
    if ( not opendir($dir_h, $dir_name) ) {
        print STDERR "Directory '$dir_name' not open for read.\n" if $ver >= 1;
        return undef;
    }
    my @all_items = readdir( $dir_h );
    close($dir_h);
    
    return [] unless scalar @all_items;

    my $items = [];
    foreach my $name ( @all_items ) {
        next if $name =~ /^\.$/;
        next if $name =~ /^\..$/;
        next if $name =~ /^\s*$/;
        push @$items, $name;
    }

    return $items;
}


sub do_cmd_sub {
    my ( $cmd_sub, $msg ) = @_;

    my $done_ok = 0;
    my $out_data = undef;
    my $sleep_time = 1;
    while ( not $done_ok ) {
        my $ret_val = $cmd_sub->();
        if ( ref $ret_val ) {
            ( $done_ok, $out_data ) = @$ret_val;
        } else {
            $done_ok = $ret_val;
        }

        unless ( $done_ok ) {
            if ( $ver >= 1 ) {
                print $msg;
                print " Sleeping $sleep_time s ...\n";
            }
            $keypress_obj->sleep_and_process_keypress( $sleep_time );
            $sleep_time = $sleep_time * $sleep_time if $sleep_time < 60*60; # one hour
        }
    }

    return $out_data;
}


sub save_item_done {
    my ( $done_list, $dconf, $item_name ) = @_;

    $done_list->{$item_name} = time();

    do_cmd_sub(
        sub { store( $done_list, $dconf->{done_list} ); },
        "Store done list to '$dconf->{done_list}' failed."
    );
    print "Item '$item_name' saved to done_list.\n" if $ver >= 5;


    if ( $dconf->{exclude_list} ) {
        my $out_fh = do_cmd_sub(
            sub {
                my $out_fh = undef;
                my $ok = open( $out_fh, '>', $dconf->{exclude_list} );
                return [ $ok, $out_fh ];
            },
            "Open file '$dconf->{exclude_list}' for write."
        );
        foreach my $item ( sort keys %$done_list ) {
            my $line = "- $item\n";
            print $out_fh $line;
        }
        do_cmd_sub(
            sub { close $out_fh; },
            "Closing file '$dconf->{exclude_list}'."
        );
    }

    return 1;
}


sub get_item_mtime {
    my ( $path ) = @_;
    
    my $stat_obj = stat( $path );
    unless ( defined $stat_obj ) {
        print "Command stat for item '$path' failed.\n" if $ver >= 1;
        return undef;
    }
    
    return $stat_obj->mtime;
}


sub mkdir_copy_mtime {
    my ( $dest_dir_path, $src_dir_path ) = @_;
    
    return 1 if -d $dest_dir_path;
    
    print "mkdir_copy_mtime '$src_dir_path' -> '$dest_dir_path'\n" if $ver >= 8;
    
    unless ( mkdir( $dest_dir_path, 0777 ) ) {
        print "Command mkdir '$dest_dir_path' failed: $^E\n" if $ver >= 1;
        return 0;
    }

    my $src_mtime = get_item_mtime( $src_dir_path );
    return 0 unless defined $src_mtime;
    
    unless ( utime(time(), $src_mtime, $dest_dir_path) ) {
        print "Command utime '$dest_dir_path' failed: $^E\n" if $ver >= 1;
        return 0;
    }
    print "mkdir_copy_mtime '$dest_dir_path' mtime set to " . (localtime $src_mtime) . "\n" if $ver >= 8;
    return 1;
}


sub mkpath_copy_mtime {
    my ( $dest_base_dir, $src_base_dir, $sub_dirs ) = @_;
    
    my $full_dest_dir = catdir( $dest_base_dir, $sub_dirs );
    return 1 if -d $full_dest_dir;

    unless ( -d $dest_base_dir ) {
        print "Error mkpath_copy_mtime dest_base_dir '$dest_base_dir' doesn't exists.\n" if $ver >= 1;
        return 0;
    }

    unless ( -d $src_base_dir ) {
        print "Error mkpath_copy_mtime src_base_dir '$src_base_dir' doesn't exists.\n" if $ver >= 1;
        return 0;
    }

    my $full_src_dir = catdir( $src_base_dir, $sub_dirs );
    unless ( -d $full_src_dir ) {
        print "Error mkpath_copy_mtime full_src_dir '$full_src_dir' doesn't exists.\n" if $ver >= 1;
        return 0;
    }

    my @dir_parts = File::Spec->splitdir( $sub_dirs );
    my $tmp_dest_dir = $dest_base_dir;
    my $tmp_src_dir = $src_base_dir;
    foreach my $dir ( @dir_parts ) {
        $tmp_dest_dir = catdir( $tmp_dest_dir, $dir );
        $tmp_src_dir = catdir( $tmp_src_dir, $dir );
        return 0 unless mkdir_copy_mtime( $tmp_dest_dir, $tmp_src_dir );
    }
    
    return 1;
}


sub do_for_dir {
    my ( $dconf, $finish_cmds, $base_dir, $sub_dir, $dir_name ) = @_;
    my $full_subdir = catdir( $sub_dir, $dir_name );
    push @$finish_cmds, [ 'mkpath_copy_mtime', $dconf->{dest_dir}, $base_dir, $full_subdir ];
    return 1;
}


sub do_for_rar_file {
    my ( $dconf, $finish_cmds, $base_dir, $sub_dir, $file_name, $dir_items ) = @_;


    my $base_name_part = undef;
    my $is_rar_archive = 0;
    my $part_num = undef;
    my $multipart_type = undef;

    if ( $file_name =~ /^(.*)\.part(\d+)\.rar$/ ) {
        $base_name_part = $1;
        $part_num = $2;
        $is_rar_archive = 1;
        $multipart_type = 'part';

    } elsif ( $file_name =~ /^(.*)\.rar$/ ) {
        $base_name_part = $1;
        $part_num = 1;
        $is_rar_archive = 1;
        # initial value, is set to '' unless other parts found
        $multipart_type = 'mr';
    }

    return ( 0, "File isn't rar archive", undef, undef ) unless $is_rar_archive;

    return ( 1, "File is part of multiparts archive, but isn't first part.", undef, undef ) if $multipart_type && ($part_num != 1);

    return -1 unless mkpath_copy_mtime( $dconf->{dest_dir}, $base_dir, $sub_dir );

    my $dest_dir = catdir( $dconf->{dest_dir}, $sub_dir );
    my $file_path = catfile( $base_dir, $sub_dir, $file_name );
    
    my $rar_ver = $ver - 10;
    $rar_ver = 0 if $rar_ver < 0;
    my %rar_conf = (
        '-archive' => $file_path,
        '-initial' => $dest_dir,
    );
    $rar_conf{'-verbose'} = $rar_ver if $rar_ver;
    my $rar_obj = Archive::Rar->new( %rar_conf );
    $rar_obj->List();
    my @files_extracted = $rar_obj->GetBareList();

    if ( $ver >= 10 ) {
        print "Input file '$file_name':\n";
        $rar_obj->PrintList();
        dumper( 'rar_obj->list', $rar_obj->{list} );
        dumper( '@files_extracted', \@files_extracted );
    }

    my @rar_parts_list = ( $file_name );

    my %files_extracted = map { $_ => 1 } @files_extracted;
    #dumper( '%files_extracted', \%files_extracted );

    my $other_part_found = 0;
    NEXT_FILE: foreach my $next_file_name ( sort @$dir_items ) {

        my $other_part_num = undef;
        if ( $multipart_type eq 'part' ) {
            if ( $next_file_name =~ /^\Q$base_name_part\E\.part(\d+)\.rar$/ ) {
                $other_part_num = $1;
            }

        } elsif ( $multipart_type eq 'mr' ) {
            if ( $next_file_name =~ /^\Q$base_name_part\E\.r(\d+)$/ ) {
                $other_part_num = $1 + 2;
            }
        }

        if ( defined $other_part_num && $part_num != $other_part_num ) {
            $other_part_found = 1;

            print "Other rar part added '$next_file_name' ($other_part_num) for base_name '$base_name_part' and type '$multipart_type'.\n" if $ver >= 5;
            push @rar_parts_list, $next_file_name;

            my $next_file_path = catfile( $base_dir, $sub_dir, $next_file_name );
            my %next_rar_conf = (
                '-archive' => $next_file_path,
                '-initial' => $dest_dir,
            );
            $rar_conf{'-verbose'} = $rar_ver if $rar_ver;
            my $next_rar_obj = Archive::Rar->new( %next_rar_conf );
            $next_rar_obj->List();

            my @next_files_extracted = $next_rar_obj->GetBareList();
            next NEXT_FILE unless scalar @next_files_extracted;

            #dumper( '@next_files_extracted', \@next_files_extracted );
            foreach my $next_file ( @next_files_extracted ) {
                next unless defined $next_file; # Archive::Rar bug?
                next if exists $files_extracted{$next_file};

                $files_extracted{$next_file} = 1;
                push @files_extracted, $next_file;
                print "Addding new extracted file '$next_file' to list from rar part num $other_part_num.\n" if $ver >= 8;
            }
        }

    } # foreach end
    $multipart_type = '' unless $other_part_found;

    print "File '$file_name' - base_name_part '$base_name_part', is_rar_archive $is_rar_archive, part_num $part_num, multipart_type '$multipart_type'\n" if $ver >= 5;


    my $res = $rar_obj->Extract(
        '-donotoverwrite' => 1,
        '-quiet' => 1,
        '-lowprio' => 1
    );
    if ( $res && $res != 1 ) {
        print "Error $res in extracting from '$file_path'.\n" if $ver >= 1;
        return ( -1, $res, [], \@rar_parts_list );
    }
    return ( 3, undef, \@files_extracted, \@rar_parts_list );
}


sub do_for_norar_file {
    my ( $dconf, $finish_cmds, $base_dir, $sub_dir, $file_name ) = @_;

    return 1 if not $dconf->{move_non_rars} && not $dconf->{cp_non_rars};

    push @$finish_cmds, [ 'mkpath_copy_mtime', $dconf->{dest_dir}, $base_dir, $sub_dir ];

    my $file_path = catfile( $base_dir, $sub_dir, $file_name );
    my $new_file_path = catfile( $dconf->{dest_dir}, $sub_dir, $file_name );

    if ( $dconf->{move_non_rars} ) {
        print "Moving '$file_path' to '$new_file_path'.\n" if $ver >= 3;
        push @$finish_cmds, [ 'move_num', $file_path, $new_file_path ];


    } elsif ( $dconf->{cp_non_rars} ) {
        print "Copying '$file_path' to '$new_file_path'.\n" if $ver >= 3;
        push @$finish_cmds, [ 'cp_num', $file_path, $new_file_path ];

    }

    return 1;
}


sub get_next_file_path {
    my ( $file_path ) = @_;

    my $num = 2;
    my $new_file_path;
    do {
        $new_file_path = $file_path . '.' . $num;
        $num++;
    } while ( -e $new_file_path );

    return $new_file_path;
}


sub rm_empty_dir {
    my ( $dir_path ) = @_;

    my $other_items = load_dir_content( $dir_path );
    return 0 unless defined $other_items;
    
    if ( scalar(@$other_items) == 0 ) {
        unless ( rmdir($dir_path) ) {
            print "Command rmdir '$dir_path' failed: $^E\n" if $ver >= 1;
            return 0;
        }
        print "Command rmdir '$dir_path' done ok.\n" if $ver >= 8;
    }

    return 1;
}


sub rm_rec_empty_dir {
    my ( $dir_path ) = @_;

    my $dir_items = load_dir_content( $dir_path );
    return 0 unless defined $dir_items;

    if ( scalar @$dir_items ) {
        foreach my $name ( @$dir_items ) {
            my $path = catfile( $dir_path, $name );
            unless ( -d $path ) {
                print "Can't remove dir with items '$dir_path' (item '$name').\n" if $ver >= 1;
                return 0;
            }
        }

        # Only dirs remains.
        foreach my $name ( @$dir_items ) {
            my $path = catfile( $dir_path, $name );
            return 0 unless rm_rec_empty_dir( $path );
        }
    }
    
    return rm_empty_dir( $dir_path );
}


sub get_rec_dir_mtime {
    my ( $dir_path ) = @_;

    my $max_mtime = get_item_mtime( $dir_path );
    return undef unless defined $max_mtime;
    #print "Dir '$dir_path' max mtime " . (localtime $max_mtime) . " (max mtime " . (localtime $max_mtime) . ")\n" if $ver >= 8;

    my $dir_items = load_dir_content( $dir_path );
    return undef unless defined $dir_items;
    return $max_mtime unless scalar @$dir_items;

    foreach my $name ( @$dir_items ) {
        my $path = catdir( $dir_path, $name );

        my $item_mtime = get_item_mtime( $path );
        $max_mtime = $item_mtime if $item_mtime && $item_mtime > $max_mtime;
        #print "Item '$path' max mtime " . (localtime $item_mtime) . " (max mtime " . (localtime $max_mtime) . ")\n" if $ver >= 8;
        
        if ( -d $path ) {
            my $subdir_max_mtime = get_rec_dir_mtime( $path );
            return undef unless defined $subdir_max_mtime;
            $max_mtime = $subdir_max_mtime if $subdir_max_mtime > $max_mtime;
            #print "Subdir '$path' max mtime " . (localtime $subdir_max_mtime) . " (max mtime " . (localtime $max_mtime) . ")\n" if $ver >= 8;
        }
    }
    return $max_mtime;
}


sub do_cmds {
    my ( $done_list, $dconf, $finish_cmds ) = @_;

    my $all_ok = 1;
    foreach my $cmd_conf ( @$finish_cmds ) {
        my $cmd = shift @$cmd_conf;
        
        # unlink
        if ( $cmd eq 'unlink' ) {
            my $full_part_path = shift @$cmd_conf;
            unless ( unlink($full_part_path) ) {
                print "Command unlink '$full_part_path' failed: $^E\n" if $ver >= 1;
                $all_ok = 0;
            }
        
        # save_done
        } elsif ( $cmd eq 'save_done' ) {
            my $item_name = shift @$cmd_conf;
            unless ( save_item_done($done_list, $dconf, $item_name) ) {
                $all_ok = 0;
            }

        # rmdir
        } elsif ( $cmd eq 'rmdir' ) {
            my $dir_name = shift @$cmd_conf;
            
            unless ( rmdir($dir_name) ) {
                print "Command rmdir '$dir_name' failed: $! $^E\n" if $ver >= 1;
                $all_ok = 0;
            }

        # move_num
        } elsif ( $cmd eq 'move_num' ) {
            my $file_path = shift @$cmd_conf;
            my $new_file_path = shift @$cmd_conf;

            $new_file_path = get_next_file_path( $new_file_path ) if -e $new_file_path;
            unless ( move($file_path, $new_file_path) ) {
               print "Command move '$file_path' '$new_file_path' failed: $^E\n" if $ver >= 1;
               $all_ok = 0;
            }

        # cp_num
        } elsif ( $cmd eq 'cp_num' ) {
            my $file_path = shift @$cmd_conf;
            my $new_file_path = shift @$cmd_conf;

            $new_file_path = get_next_file_path( $new_file_path) if -e $new_file_path;
            unless ( cp($file_path, $new_file_path) ) {
               print "Command cp '$file_path' '$new_file_path' failed: $^E\n" if $ver >= 1;
               $all_ok = 0;
            }

        # mkpath_copy_mtime
        } elsif ( $cmd eq 'mkpath_copy_mtime' ) {
            my $dest_dir = shift @$cmd_conf;
            my $src_dir = shift @$cmd_conf;
            my $sub_dirs = shift @$cmd_conf;

            unless ( mkpath_copy_mtime( $dest_dir, $src_dir, $sub_dirs ) ) {
               $all_ok = 0;
            }

        # rm_empty_dir
        } elsif ( $cmd eq 'rm_empty_dir' ) {
            my $dir_path = shift @$cmd_conf;
            $all_ok = 0 unless rm_empty_dir( $dir_path );

        # rm_rec_empty_dir
        } elsif ( $cmd eq 'rm_rec_empty_dir' ) {
            my $dir_path = shift @$cmd_conf;
            $all_ok = 0 unless rm_rec_empty_dir( $dir_path );

        }
    
    } # foreach

    return $all_ok;
}



sub unrar_dir {
    my ( $done_list, $undo_cmds, $finish_cmds, $dconf, $sub_dir, $deep ) = @_;

    my $base_dir = $dconf->{'src_dir'};

    my $dir_name = catdir( $base_dir, $sub_dir );
    print "Entering directory '$dir_name'\n" if $ver >= 3;
    
    my $items = load_dir_content( $dir_name );
    return 0 unless defined $items;
    return 1 unless scalar @$items;

    $keypress_obj->process_keypress();

    my $space = '  ' x $deep;

    # dirs
    foreach my $name ( sort @$items ) {
        my $new_sub_dir = catdir( $sub_dir, $name );
        next if exists $done_list->{ $new_sub_dir };

        my $path = catdir( $base_dir, $new_sub_dir );

        # directories only
        next unless -d $path;

        if ( $deep + 1 == $dconf->{done_list_deep} ) {
            my $max_mtime = get_rec_dir_mtime( $path );
            return 0 unless defined $max_mtime;
            
            print "Directory '$path' max mtime " . (localtime $max_mtime) . "\n" if $ver >= 4;
            if ( defined $dconf->{min_dir_mtime} ) {
                if ( time() - $dconf->{min_dir_mtime} < $max_mtime ) {
                    print "Directory '$path' max mtime " . (localtime $max_mtime) . " is too high.\n" if $ver >= 2;
                    next;
                }
                print "Directory '$path' max mtime " . (localtime $max_mtime) . " is low enought.\n" if $ver >= 4;
            }
        }

        do_for_dir( $dconf, $finish_cmds, $base_dir, $sub_dir, $name );

        if ( $dconf->{recursive} ) {
            
            # Going deeper and deeper inside directory structure.
            if ( unrar_dir( $done_list, $undo_cmds, $finish_cmds, $dconf, $new_sub_dir, $deep+1) ) {
                print "Dir '$new_sub_dir' unrar status ok.\n" if $ver >= 5;
                if ( $deep < $dconf->{done_list_deep} ) {

                    # Add this to done list.
                    push @$finish_cmds, [ 'save_done', $new_sub_dir ];

                    # Finish command.
                    if ( scalar @$finish_cmds ) {
                        dumper( "Finishing prev sub_dir '$sub_dir', deep $deep", $finish_cmds ) if $ver >= 5;
                        do_cmds( $done_list, $dconf, $finish_cmds );
                    }

                    # Empty stacks.
                    $undo_cmds = [];
                    $finish_cmds = [];
                }
                next;

            }

            # Unrar failed.
            print "Dir '$new_sub_dir' unrar failed.\n" if $ver >= 5;
            if ( $deep < $dconf->{done_list_deep} ) {
                # Undo command.
                my $dest_path = catdir( $dconf->{dest_dir}, $new_sub_dir );
                push @$undo_cmds, [ 'rm_rec_empty_dir', $dest_path ];
                dumper( "Undo prev sub_dir '$sub_dir', deep $deep", $undo_cmds ) if $ver >= 5;
                do_cmds( $done_list, $dconf, $undo_cmds );
                
                # Empty stacks.
                $undo_cmds = [];
                $finish_cmds = [];
                next;
            }
            
            # Unrar failed and nothing to undo (too deeper).
            return 0;
        }

    } # end foreach dir


    my $extrace_error_found = 0;
    my $files_done = {};
    # find first parts or rars
    foreach my $name ( sort @$items ) {
        my $file_sub_path = catfile( $sub_dir, $name );
        next if exists $done_list->{ $file_sub_path };

        my $path = catdir( $dir_name, $name );
        # all files
        if ( -f $path ) {
            #print "$space$name ($path) " if $ver >= 3;

            if ( $name !~ /\.(r\d+|rar)$/ ) {
                print "File '$name' isn't RAR archive.\n" if $ver >= 4;
                next;
            }

            my ( $rar_rc, $extract_err, $files_extracted, $rar_parts_list ) = do_for_rar_file(
                $dconf, $finish_cmds, $base_dir, $sub_dir, $name, $items
            );

            print "$sub_dir, $name -- rar_rc $rar_rc, $extract_err\n" if $ver >= 8;
            if ( $ver >= 9 ) {
                dumper( "files_extracted", $files_extracted );
                dumper( "rar_parts_list", $rar_parts_list );
            }
            if ( $rar_rc != 0 ) {
                # No first part of multipart archive.
                next if $rar_rc == 1;

                # If error -> do not process these archives as normal files
                # in next code.
                foreach my $part ( @$rar_parts_list ) {
                    my $part_sub_path = catfile( $sub_dir, $part );
                    $files_done->{ $part_sub_path } = 1;
                }

                # Add all extracted files to undo list.
                foreach my $ext ( @$files_extracted ) {
                    print "Extracted archive '$ext' processed.\n" if $ver >= 5;
                    my $ext_path = catfile( $dconf->{dest_dir}, $sub_dir, $ext );
                    next unless -e $ext_path;
                    push @$undo_cmds, [ 'unlink', $ext_path ];
                }

                if ( $extract_err ) {
                    print "Rar archive extractiong error: $extract_err\n" if $ver >= 1;
                    return 0;

                } else {
                    # remove rar archives from list
                    foreach my $part ( @$rar_parts_list ) {
                        print "Archive part '$part' processed.\n" if $ver >= 5;
                        my $part_path = catfile( $sub_dir, $part );
                        push @$finish_cmds, [ 'save_done', $part_path ] if $deep < $dconf->{done_list_deep};
                        if ( $dconf->{remove_done} ) {
                            my $full_part_path = catdir( $dir_name, $part );
                            push @$finish_cmds, [ 'unlink', $full_part_path ];
                        }
                    }
                }
            }
        }
    }


    # no rar files
    foreach my $name ( sort @$items ) {
        my $file_sub_path = catfile( $sub_dir, $name );
        next if exists $done_list->{ $file_sub_path };
        next if exists $files_done->{ $file_sub_path };

        my $path = catdir( $dir_name, $name );
        # all files
        if ( -f $path ) {
            #print "$space$name ($path) " if $ver >= 3;
            do_for_norar_file( $dconf, $finish_cmds, $base_dir, $sub_dir, $name );
            push @$finish_cmds, [ 'save_done', $file_sub_path ] if $deep < $dconf->{done_list_deep};
        }
    }

    if ( $sub_dir ) {
        # remove empty dirs
        if ( $dconf->{remove_done} ) {
            push @$finish_cmds, [ 'rm_rec_empty_dir', $dir_name ];
        }
    }

    if ( $deep < $dconf->{done_list_deep} ) {
        # Finish prev.
        if ( scalar @$finish_cmds ) {
            dumper( "finishing prev sub_dir '$sub_dir'", $finish_cmds ) if $ver >= 5;
            do_cmds( $done_list, $dconf, $finish_cmds );
            $finish_cmds = [];
        }
    }

    return 1;
}


# debug
if ( 0 && $run_type eq 'test' ) {
    
    my $dconf = $dirs_conf->[0];
    my $base_dir = $dconf->{src_dir};
    my $sub_dir = 'subdir6/subdir5A-file';

    my $full_path = catdir( $base_dir, $sub_dir );
    my $dir_items = load_dir_content( $full_path );
    exit unless defined $dir_items;
    
    do_for_rar_file( 
        $dconf,
        [], # $finish_cmds
        $base_dir,
        $sub_dir,
        'test14.part1.rar', # $file_name,
        $dir_items
    );
    $keypress_obj->cleanup_before_exit();
    exit;
}


foreach my $dconf ( @$dirs_conf ) {

    # skip if only one selected
    if ( defined $only_dconf_name && $dconf->{name} ne $only_dconf_name ) {
        print "Skipping configuration $dconf->{name} (!=$only_dconf_name).\n" if $ver >= 2;
        next;
    }
    
    unless ( -d $dconf->{src_dir} ) {
        print "Input directory '$dconf->{src_dir}' doesn't exists.\n" if $ver >= 1;
        next;
    }

    unless ( -d $dconf->{dest_dir} ) {
        print "Output directory '$dconf->{dest_dir}' doesn't exists.\n" if $ver >= 1;
        next;
    }

    my $done_list = undef;
    if ( -e $dconf->{done_list} ) {
        $done_list = retrieve( $dconf->{done_list} );
    } else {
        $done_list = {

        };
    }

    dumper( 'dconf', $dconf ) if $ver >= 5;
    unrar_dir(
        $done_list,
        [], # $undo_cmds
        [], # $finish_cmds
        $dconf,
        '', # $sub_dir
        0  # $deep
    );

    dumper( "done list for '$dconf->{name}':", $done_list ) if $ver >= 5;

}

$keypress_obj->cleanup_before_exit();