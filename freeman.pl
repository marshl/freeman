use warnings;
use strict;
use DBI;
#use File::Slurp;
use File::Temp qw/ tempfile /;
#use XML::Twig;

my @clobTypes =  ( 
    { 
        type => 'xview',
        dir => 'XviewDefinitions\\CREATE',
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
        dir => 'Mapsets',
        stmt => "SELECT x.domain || '.xml', x.metadata.getClobVal() FROM envmgr.env_mapsets_metadata x",
    },
);
 
die "Usage: clobcheck.pl code_source_folder host port sid username password\n" unless @ARGV == 6;
my ( $code_source_folder, $host, $port, $sid, $username, $password ) = @ARGV;

die "Invalid folder $code_source_folder" if not -d $code_source_folder;

my $dbh = DBI->connect( "dbi:Oracle:host=$host;port=$port;sid=$sid;", $username, $password ) or die $DBI::errstr;
# Expand the read length to a safe size
$dbh->{LongReadLen} = 512 * 1024;

for ( @clobTypes ) {
    print "\nComparing " . $$_{'type'} . "\n";
    my $sth = $dbh->prepare( $$_{'stmt'} ) or die $DBI::errstr;
    $sth->execute or die $DBI::errstr;

    my ( $clob_name, $clob_data );
    $sth->bind_columns( \$clob_name, \$clob_data );
    
    while ( $sth->fetch ) {
        my $filename = $code_source_folder.'\\'.$$_{'dir'}.'\\'.$clob_name;
        my $temp_clob = $clob_data;
        if ( not -e $filename ) {
            print "Definition file not found: $filename\n";
            next;
        }

        # Read file contents (without slurp)
        my $file_contents;
        {
            open ( my $fh, '<', $filename ) or die $!;
            local $/ = undef;
            $file_contents = <$fh>;
        }
        
        # Strip whitespace and comments from both files
        # So it doesn't affect diffing
        $file_contents =~ s/\s//g;
        $temp_clob =~ s/\s//g;
        
        $file_contents =~ s/<!--.*-->//g;
        $temp_clob =~ s/<!--.*-->//g;
        
        $file_contents =~ s/<\?.*\?>//g;
        $temp_clob =~ s/<\?.*\?>//g;
        
        print "Definition mismatch: $clob_name\n" if $temp_clob ne $file_contents;
        
        # TortoiseMerge Diff
        # if ( $temp_clob ne $file_contents )
        # {
            # my ( $tfh, $tempfile ) = tempfile();
            # print $tfh $clob_data;
            # close $tfh;
            # system( "tortoisemerge /mine:$tempfile /theirs:$filename")
        # }
        
        # Overwrite xviews
        # if ( $$_{'type'} eq 'xview' and $temp_clob ne $file_contents )
        # {
            # open FH,">$filename";
            # print FH $clob_data;
        # }
    }
}

$dbh->disconnect();
