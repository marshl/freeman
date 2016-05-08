###############################################################################
#
# Fox REconciliation Enterprise MANager
#
# "The right man in the wrong place can make all the difference in the world."
#
####

use strict;
use warnings;

use DBI;
use Data::Dumper;
use English qw(-no_match_vars);
use File::Basename;
use File::Find;
use File::Spec;
use File::Temp qw(tempfile);
use Getopt::Long;

die "Usage: freeman.pl code_source_dir host port sid username password\n" if @ARGV != 6;
my ( $code_source_dir, $host, $port, $sid, $username, $password ) = @ARGV;
die "Invalid folder $code_source_dir" if not -d $code_source_dir;

my $dbh = DBI->connect( "dbi:Oracle:host=$host;port=$port;sid=$sid;", $username, $password ) or die "Error connecting to DB: $DBI::errstr";
# Expand the read length to a safe size
$dbh->{LongReadLen} = 512 * 1024;

compare_directories($dbh, $code_source_dir);
compare_patches($dbh, $code_source_dir);
compare_database_source($dbh, $code_source_dir);

sub compare_directories {

    my ( $dbh, $code_source_dir ) = @ARG;

    my @directory_types = get_directory_types();

    DIRECTORY_TYPE:
    foreach my $directory_type ( @directory_types ) {
        print "\nComparing $directory_type->{'name'}\n";

        my $directory_path = File::Spec->catfile( $code_source_dir, $directory_type->{'directory'} );

        if ( not -d $directory_path ) {
            print "Directory not found: $directory_path\n";
            next DIRECTORY_TYPE;
        }

        my $statement = $dbh->prepare( $directory_type->{'statement'} ) or die $dbh->errstr;
        my @file_list;
        find(
            sub {
                if ( m/^.+?$directory_type->{'extension'}$/xs ) {
                    push @file_list, $File::Find::name;
                }
            },
            $directory_path
        );

        FULLPATH:
        foreach my $fullpath ( @file_list ) {
            my $filename = basename($fullpath);
            my ($without_extension) = fileparse($fullpath, qr/[.][^.]*/x);

            $statement->execute($without_extension) or die "Error executing statement: $statement->errstr()";
            my $filedata = $statement->fetchrow();

            if ( $statement->rows > 1 ) {
                print "Too many records found for $filename\n";
                next FULLPATH;
            }

            if ( $statement->rows == 0 ) {
                print "New File: $filename\n";
                next FULLPATH;
            }

            my $local_file_content;
            {
                open ( my $fh, '<', $fullpath ) or die "Could not open file $fullpath: $OS_ERROR";
                local $INPUT_RECORD_SEPARATOR = undef;
                $local_file_content = <$fh>;
                close $fh;
            }

            my $patterns = $directory_type->{'remove_patterns'};
            foreach my $pattern ( @{$patterns} ) {
                $local_file_content =~ s/$pattern//g;
                $filedata =~ s/$pattern//g;
            }

            if ( $local_file_content ne $filedata ) {
                print "Modified: $filename\n";
            }
        }
    }
}

sub compare_patches {
    my ( $dbh, $code_source_dir ) = @ARG;
    
    print "\nChecking patch runs\n";
    
    my $patch_directory = File::Spec->catfile( $code_source_dir, 'DatabasePatches' );

    my @patch_list;
    find(
        sub {
            if ( m/^.+?\.sql$/ ) {
                push @patch_list, $File::Find::name;
            }
        },
        $patch_directory
    );
    
    my $statement = $dbh->prepare( <<"QUERY_END"
SELECT pr.id FROM promotemgr.patch_runs pr
WHERE pr.patch_label = ?
AND pr.patch_number = ?
AND pr.ignore_flag IS NULL
QUERY_END
    ) or die $dbh->errstr;
    
    foreach my $patch ( @patch_list ) {
        my $filename = basename($patch);
        $filename =~ /^(?<patch_type>\D+?)(?<patch_number>\d+?) \(.+?\)\.sql/;
        
        $statement->execute( $LAST_PAREN_MATCH{'patch_type'}, $LAST_PAREN_MATCH{'patch_number'} )
            or die "Error executing statement: $statement->errstr()";
        my $filedata = $statement->fetchrow();
        
        if ( $statement->rows == 0 ) {
            print "New Patch: $filename\n";
        }
    }
}

$dbh->disconnect();
sub compare_database_source {
    my ($dbh, $code_source_dir) = @ARG;
    
    print "\nComparing packages:\n";
    
    my $source_directory = File::Spec->catfile( $code_source_dir, 'DatabaseSource' );

    if ( not $dbh->do( <<"QUERY_END"
CREATE USER freemanmgr IDENTIFIED BY "password"
QUERY_END
    ) ) {
        if ( $dbh->err == 1920 ) {
            print "FREEMANMGR already exists, and will not be recreated.\n";
        }
        else {
            die $dbh->errstr;
        }
    }
    
    my @file_list;
    find(
        sub {
            if ( m/^.+?\.(pkb|pks)$/ ) {
                push @file_list, $File::Find::name;
            }
        },
        $source_directory
    );
    
    my %file_extensions = ( '.pks' => 'PACKAGE', '.pkb' => 'PACKAGE_BODY' );

    PACKAGE:
    for my $fullpath ( @file_list ) {
        my ($filename, $directory, $extension) = fileparse($fullpath, keys %file_extensions);
        my $file_content = read_file_text( $fullpath );
        my $object_type = $file_extensions{$extension};
        
        if ( not $file_content =~ /CREATE OR REPLACE.+?(?<schema>[^.\s"]+)"?\."?(?<object>[^.\s"]+)/ ) {
            print "$filename$extension did not match standard creation syntax.\n";
        }
        
        my $schema_name = uc $LAST_PAREN_MATCH{'schema'};
        my $object_name = uc $LAST_PAREN_MATCH{'object'};
        $file_content =~ s/(CREATE OR REPLACE.+?)([^.\s]+)\.([^.\s]+)/${1}FREEMANMGR.$3/;

        if ( not $dbh->do( $file_content ) ) {
            if ( $dbh->err != 24344 ) { 
                die $dbh->errstr;
            }
        } 
        
        my $statement = $dbh->prepare(
"SELECT " .
"DBMS_LOB.COMPARE( " .
"  REGEXP_REPLACE( REGEXP_REPLACE( REGEXP_REPLACE( DBMS_METADATA.GET_DDL( object_type => '$object_type', name => '$object_name', schema => 'FREEMANMGR' ), 'FREEMANMGR', '$schema_name' ), '/', ''), '\\s', '')" .
", REGEXP_REPLACE( REGEXP_REPLACE( DBMS_METADATA.GET_DDL( object_type => '$object_type', name => '$object_name', schema => '$schema_name' ), '/', ''), '\\s', '' )" .
") result " .
"FROM dual"
        ) or die $dbh->errstr;
        
        if ( not $statement->execute() ) {
            if ( $dbh->err == 31603 ) {
                print "New package: $filename$extension\n";
                next PACKAGE;
            }
            else {
                die $dbh->errstr;
            }
        }
        
        my $compare_result = $statement->fetchrow();
        if ( $compare_result != 0 ) {
            print "Modified: $filename$extension\n";
        }
    }
    
    $dbh->do( "DROP USER freemanmgr CASCADE" )
        or die $dbh->errstr;
}

sub read_file_text {
    my ($filename) = @ARG;
    open ( my $fh, '<', $filename ) or die "Could not open file $filename: $OS_ERROR";
    local $INPUT_RECORD_SEPARATOR = undef;
    my $filedata = <$fh>;
    close $fh;
    return $filedata;
}

sub get_directory_types {

    my $whitespace_regex = '\s';
    my $js_regex = '\/[*].+?[*]\/';
    my $xml_regex = '<!--.\*-->';

    return (
    {
        name => 'DocLib Types',
        directory => 'DocLibTypes',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT dlt.xml_data.getClobVal()
FROM doclibmgr.document_library_types dlt
WHERE dlt.document_library_type = ?
END_QUERY
    },
    
    {
        name => 'Document Templates',
        directory => 'DocumentTemplates',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT dt.xml_data.getClobVal()
FROM decmgr.document_templates dt
WHERE dt.name = ?
END_QUERY
    },
    
    {
        name => 'File Folder Types',
        directory => 'FileFolderTypes',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT fft.xml_data.getClobVal()
FROM decmgr.file_folder_types fft
WHERE fft.file_folder_type = ?
END_QUERY
    },
    
    {
        name => 'Fox5Modules - JavaScript',
        directory => 'Fox5Modules',
        extension => '\.js',
        remove_patterns => [ $whitespace_regex, $js_regex ],
        statement => <<"END_QUERY"
SELECT data
FROM envmgr.fox_components_fox5 fc5
WHERE fc5.name = 'js/' || ?
END_QUERY
    },

    {
        name => 'Fox5Modules - Modules',
        directory => 'Fox5Modules',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT data
FROM envmgr.fox_components_fox5 fc5
WHERE fc5.name = ?
END_QUERY
    },

    {
        name => 'FoxModules - Modules',
        directory => 'FoxModules',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT fc.data FROM envmgr.fox_components fc
WHERE fc.type = 'module'
AND fc.name = ?
END_QUERY
    },
    
    {
        name => 'Mapsets',
        directory => 'Mapsets',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT emm.metadata.getClobVal()
FROM envmgr.env_mapsets_metadata emm
WHERE emm.domain = ?
END_QUERY
    },
    
    {
        name => 'NavBar Action Groups',
        directory => 'NavBarActionGroups',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT x.xml_data.getClobVal()
FROM envmgr.nav_bar_action_groups x
WHERE x.mnem = ?
END_QUERY
    },

    {
        name => 'Navbar Categories',
        directory => 'NavBarActionCategories',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT x.xml_data.getClobVal()
FROM envmgr.nav_bar_action_categories x
WHERE x.mnem = ?
END_QUERY
    },
    
    {
        name => 'Port Folder Types',
        directory => 'PortalFolderTypes',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT pft.xml_data.getClobVal()
FROM decmgr.portal_folder_types pft
WHERE pft.portal_folder_type = ?
END_QUERY
    },
    
    {
        name => 'Report Definitions',
        directory => 'ReportDefinitions',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT rd.xml_data.getClobVal()
FROM reportmgr.report_definitions rd
WHERE rd.domain = ?
END_QUERY
    },
    
    {
        name => 'Resource Types',
        directory => 'ResourceTypes',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT rt.xml_data.getClobVal()
FROM decmgr.resource_types rt
WHERE rt.res_type = ?
END_QUERY
    },
    
    {
        name => 'Tally Types',
        directory => 'TallyTypes',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT tt.xml_data.getClobVal()
FROM bpmmgr.tally_types tt
WHERE tt.tally_type = ?
END_QUERY
    },
    
    {
        name => 'Work Request Types',
        directory => 'ApplicationMetadata\\WorkRequestTypes',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT wrt.xml_data.getClobVal()
FROM iconmgr.work_request_types wrt
WHERE wrt.mnem = ?
END_QUERY
    },
    
    {
        name => 'WUA Preference Categories',
        directory => 'WUAPreferenceCategories',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT wpc.xml_data.getClobVal()
FROM securemgr.wua_preference_categories wpc
WHERE wpc.category_name = ?
END_QUERY
    },

    {
        name => 'Xview Definitions',
        directory => 'XviewDefinitions',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT x.xview_metadata.getClobVal()
FROM xviewmgr.xview_definition_metadata x
WHERE x.file_name = ? || '.xml'
END_QUERY
    },

    {
        name => 'Xview 2 Definitions',
        directory => 'Xview2Definitions',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT x.xview_metadata_formatted
FROM xviewmgr.xview2_definition_metadata x
WHERE x.file_name = ? || '.xml'
END_QUERY
    },

    );
}