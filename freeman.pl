###############################################################################
#
# Fox REconciliation Execution MANager
# 
# "The right man in the wrong place can make all the difference in the world."
#
####

use warnings;
use strict;
use DBI;
use File::Temp qw/ tempfile /;
use Data::Dumper;
use File::Find::Rule;
use File::Basename;

my @clobTypes =  (
    { 
        name => 'Fox5Modules - JavaScript',
        dir => 'Fox5Modules',
        extension => '*.js',
        remove_patterns => [ '\s', '\/\*.+?\*\/' ],
        stmt => "
SELECT data
FROM envmgr.fox_components_fox5 fc5
WHERE fc5.name = 'js/' || ?",
    },
     { 
        name => 'Fox5Modules - Modules',
        dir => 'Fox5Modules',
        extension => '*.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT data
FROM envmgr.fox_components_fox5 fc5
WHERE fc5.name = ?",
    },
    
    { 
        name => 'xview',
        dir => 'XviewDefinitions',
        extension => '*.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT x.xview_metadata.getClobVal()
FROM xviewmgr.xview_definition_metadata x
WHERE x.file_name = ? || '.xml'",
    },
    { 
        name => 'xview2',
        dir => 'Xview2Definitions',
        extension => '*.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT x.xview_metadata_formatted
FROM xviewmgr.xview2_definition_metadata x
WHERE x.file_name = ? || '.xml'",
    },
    { 
        name => 'navbar_groups',
        dir => 'NavBarActionGroups\\',
        extension => '*.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT x.xml_data.getClobVal()
FROM envmgr.nav_bar_action_groups x
WHERE x.mnem = ?",
    },
    {
        name => 'navbar_categories',
        dir => 'NavBarActionCategories\\',
        extension => '*.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT x.xml_data.getClobVal()
FROM envmgr.nav_bar_action_categories x
WHERE x.mnem = ?",
    },
    { 
        name => 'mapsets',
        dir => 'Mapsets\\Environmental',
        extension => '*.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT x.metadata.getClobVal()
FROM envmgr.env_mapsets_metadata x
WHERE x.domain = ?",
    },
);
 
die "Usage: clobcheck.pl code_source_folder host port sid username password\n" unless @ARGV == 6;
my ( $code_source_folder, $host, $port, $sid, $username, $password ) = @ARGV;

die "Invalid folder $code_source_folder" if not -d $code_source_folder;

my $dbh = DBI->connect( "dbi:Oracle:host=$host;port=$port;sid=$sid;", $username, $password ) or die $DBI::errstr;
# Expand the read length to a safe size
$dbh->{LongReadLen} = 512 * 1024;

foreach my $clobType ( @clobTypes ) {
    print "\nComparing " . $clobType->{'name'} . "\n";
    
    my $fullpath = $code_source_folder . '\\' . $clobType->{'dir'};
    # opendir(D, $fullpath ) or die "Can't open directory $fullpath: $!";
    
    # my @fileList = grep !/^\.\.?$/, readdir(D);
    
    my $statement = $dbh->prepare( $clobType->{'stmt'} ) or die $DBI::errstr;
    print Dumper($clobType);
    my @fileList = File::Find::Rule->file->name( $clobType->{'extension'} )->in($fullpath);
    #print Dumper(@fileList);
    
    foreach my $fullpath ( @fileList ) {
        my $filename = basename($fullpath);
        (my $without_extension = $filename) =~ s/\.[^.]+$//;
        
        print $without_extension . "\n";
        
        $statement->execute($without_extension) or die $statement->errstr();
        my $filedata = $statement->fetchrow();
        
        if ( $statement->rows > 1 ) {
            print "Too many records found for $filename\n";
            next;
        }
        
        #die "No data found." if not defined $data and not defined $bindata;
        if ( $statement->rows == 0 ) {
            print "No data found for $filename\n";
            next;
        }
        
        my $local_file_content;
        {
            open ( my $fh, '<', $fullpath ) or die "Could not open file $fullpath: $!";
            local $/ = undef;
            $local_file_content = <$fh>;
        }
        
        #if ( defined $$clobType{'remove_patterns'} ) {
        #print Dumper($clobType{'remove_patterns'});
        my $patterns = $clobType->{'remove_patterns'};
        #print Dumper(@patterns);
        foreach my $pattern ( @$patterns ) {
            #print '\t' . Dumper($pattern);
            #print "$pattern\n";
            $local_file_content =~ s/($pattern)//g;
            $filedata =~ s/($pattern)//g;
        }
        #}
        
        if ( $local_file_content ne $filedata ) {
            print "File mismatch $filename\n";
        }
    }
}

$dbh->disconnect();
