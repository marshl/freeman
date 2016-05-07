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

my @directory_types = get_directory_types();

if ( @ARGV != 6 ) {
    die "Usage: freeman.pl code_source_folder host port sid username password\n";
}
my ( $code_source_folder, $host, $port, $sid, $username, $password ) = @ARGV;

die "Invalid folder $code_source_folder" if not -d $code_source_folder;

my $dbh = DBI->connect( "dbi:Oracle:host=$host;port=$port;sid=$sid;", $username, $password ) or die "Error connecting to DB: $DBI::errstr";
# Expand the read length to a safe size
$dbh->{LongReadLen} = 512 * 1024;

DIRECTORY_TYPE:
foreach my $directory_type ( @directory_types ) {
    print "\nComparing $directory_type->{'name'}\n";

    my $directory_path = File::Spec->catfile( $code_source_folder, $directory_type->{'directory'} );

    if ( not -d $directory_path ) {
        print "Directory not found: $directory_path\n";
        next DIRECTORY_TYPE;
    }

    my $statement = $dbh->prepare( $directory_type->{'statement'} ) or die $dbh->errstr;
    #print Dumper($directory_type);
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
        my ($without_extension) = fileparse($fullpath, qr/[.][^.]*/);

        #print "$without_extension\n";

        $statement->execute($without_extension) or die $statement->errstr();
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

$dbh->disconnect();

sub get_directory_types {

    my $whitespace_regex = '\s';
    my $js_regex = '\/[*].+?[*]\/';
    my $xml_regex = '<!--.\*-->';

    return (
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
        name => 'xview',
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
        name => 'Xview 2s',
        directory => 'Xview2Definitions',
        extension => '\.xml',
        remove_patterns => [ $whitespace_regex, $xml_regex ],
        statement => <<"END_QUERY"
SELECT x.xview_metadata_formatted
FROM xviewmgr.xview2_definition_metadata x
WHERE x.file_name = ? || '.xml'
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
    );
}