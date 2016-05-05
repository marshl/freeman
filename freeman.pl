use warnings;
use strict;
use DBI;
use File::Slurp;

my @clobTypes = 
( 
    { 
        type => 'xview',
        dir => 'XviewDefinitions\\',
        stmt => 'SELECT x.file_name, x.xview_metadata.getClobVal() FROM xviewmgr.xview_definition_metadata x',
    },
    { 
        type => 'xview2',
        dir => 'XviewDefinitions\\',
        stmt => 'SELECT x.file_name, x.xview_metadata_formatted FROM xviewmgr.xview2_definition_metadata x',
    },
    { 
        type => 'navbar_groups',
        dir => 'NavBarActionGroups\\',
        stmt => "SELECT x.mnem || '.xml', x.xml_data.getClobVal() FROM envmgr.nav_bar_action_groups x",
    },
    { 
        type => 'navbar_categories',
        dir => 'NavBarActionCategories\\',
        stmt => "SELECT x.mnem || '.xml', x.xml_data.getClobVal() FROM envmgr.nav_bar_action_categories x",
    },
    { 
        type => 'mapsets',
        dir => 'Mapsets\\Environmental\\',
        stmt => "SELECT x.domain || '.xml', x.metadata.getClobVal() FROM envmgr.env_mapsets_metadata x",
    },
);
 
die "Usage: clobcheck.pl code_source_folder host sid xviewmgr_password\n" unless @ARGV == 4;
my ( $code_source_folder, $host, $sid, $passwd ) = @ARGV;

die "Invalid folder $code_source_folder" if not -d $code_source_folder;

my $dbh = DBI->connect( "dbi:Oracle:host=$host;sid=$sid", "xviewmgr", $passwd ) or die $DBI::errstr;
# Expand the read length to a safe size
$dbh->{LongReadLen} = 512 * 1024;

for ( @clobTypes )
{
    print "\nComparing " . $$_{'type'} . "\n";
    my $sth = $dbh->prepare( $$_{'stmt'} ) or die $DBI::errstr;
    $sth->execute or die $DBI::errstr;

    my ( $clob_name, $clob_data );
    $sth->bind_columns( \$clob_name, \$clob_data );
    while ( $sth->fetch ) {
        my $filename = $code_source_folder.$$_{'dir'}.$clob_name;
        
        if ( not -e $filename ) {
            print "Could not find definition file $filename\n";
            next;
        }

        my $file_contents = read_file( $filename );
        # Strip whitespace and comments from both files
        $file_contents =~ s/\s//g;
        $clob_data =~ s/\s//g;
        
        $file_contents =~ s/<!--.*-->//g;
        $clob_data =~ s/<!--.*-->//g;
        
        $file_contents =~ s/<\?.*\?>//g;
        $clob_data =~ s/<\?.*\?>//g;
        
        print "Definition mismatch for $clob_name\n" if $clob_data ne $file_contents;
    }
}

$dbh->disconnect();
