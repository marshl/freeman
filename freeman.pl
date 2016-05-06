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

my @clobTypes = getClobTypes();

die "Usage: clobcheck.pl code_source_folder host port sid username password\n" unless @ARGV == 6;
my ( $code_source_folder, $host, $port, $sid, $username, $password ) = @ARGV;
# GetOptions(
    # 'folder=s' => \$code_source_folder,
    # 'host=s' => \$host,
    # 'port=s' => \$port,
    # 'sid=s' => \$sid,
    # 'username=s' => \$username,
    # 'password=s' => \$password
# );

die "Invalid folder $code_source_folder" if not -d $code_source_folder;

my $dbh = DBI->connect( "dbi:Oracle:host=$host;port=$port;sid=$sid;", $username, $password ) or die "Error connecting to DB: $DBI::errstr";
# Expand the read length to a safe size
$dbh->{LongReadLen} = 512 * 1024;

CLOBTYPE:
foreach my $clobType ( @clobTypes ) {
    print "\nComparing $clobType->{'name'}\n";

    # my $directoryPath = $code_source_folder . '\\' . $clobType->{'dir'};
    my $directoryPath = File::Spec->catfile( $code_source_folder, $clobType->{'dir'} );

    if ( not -d $directoryPath ) {
        print "Directory not found: $directoryPath\n";
        next CLOBTYPE;
    }
    #    opendir(D, $fullpath ) or die "Can't open directory $fullpath: $!";

    # my @fileList = grep !/^\.\.?$/, readdir(D);

    my $statement = $dbh->prepare( $clobType->{'stmt'} ) or die $dbh->errstr;
    print Dumper($clobType);
    my @fileList;# = File::Find->file->name( $clobType->{'extension'} )->in($directoryPath);
    find(
        sub {
            if ( m/^.+?$clobType->{'extension'}$/ ) {
                push @fileList, $File::Find::name;
            }
        },
        $directoryPath
    );
    #print Dumper(\@fileList);

    FULLPATH:
    foreach my $fullpath ( @fileList ) {
        my $filename = basename($fullpath);
        #(my $without_extension = $filename) =~ s/\.[^.]*$//;
        my ($without_extension) = fileparse($fullpath, qr/\.[^.]*/);

        print "$without_extension\n";

        $statement->execute($without_extension) or die $statement->errstr();
        my $filedata = $statement->fetchrow();

        if ( $statement->rows > 1 ) {
            print "Too many records found for $filename\n";
            next FULLPATH;
        }

        #die "No data found." if not defined $data and not defined $bindata;
        if ( $statement->rows == 0 ) {
            print "No data found for $filename\n";
            next FULLPATH;
        }

        my $local_file_content;
        {
            open ( my $fh, '<', $fullpath ) or die "Could not open file $fullpath: $OS_ERROR";
            local $INPUT_RECORD_SEPARATOR = undef;
            $local_file_content = <$fh>;
        }

        my $patterns = $clobType->{'remove_patterns'};
        foreach my $pattern ( @{$patterns} ) {
            $local_file_content =~ s/$pattern//g;
            $filedata =~ s/$pattern//g;
        }
        #}

        if ( $local_file_content ne $filedata ) {
            print "File mismatch $filename\n";
        }
    }
}

$dbh->disconnect();

sub getClobTypes {
    return (
    {
        name => 'Fox5Modules - JavaScript',
        dir => 'Fox5Modules',
        extension => '\.js',
        remove_patterns => [ '\s', '\/\*.+?\*\/' ],
        stmt => "
SELECT data
FROM envmgr.fox_components_fox5 fc5
WHERE fc5.name = 'js/' || ?",
    },

    {
        name => 'Fox5Modules - Modules',
        dir => 'Fox5Modules',
        extension => '\.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT data
FROM envmgr.fox_components_fox5 fc5
WHERE fc5.name = ?",
    },

    {
        name => 'xview',
        dir => 'XviewDefinitions',
        extension => '\.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT x.xview_metadata.getClobVal()
FROM xviewmgr.xview_definition_metadata x
WHERE x.file_name = ? || '.xml'",
    },

    {
        name => 'Xview 2s',
        dir => 'Xview2Definitions',
        extension => '\.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT x.xview_metadata_formatted
FROM xviewmgr.xview2_definition_metadata x
WHERE x.file_name = ? || '.xml'",
    },

    {
        name => 'Xviews',
        dir => 'NavBarActionGroups\\',
        extension => '\.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT x.xml_data.getClobVal()
FROM envmgr.nav_bar_action_groups x
WHERE x.mnem = ?",
    },

    {
        name => 'Navbar Categories',
        dir => 'NavBarActionCategories\\',
        extension => '\.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT x.xml_data.getClobVal()
FROM envmgr.nav_bar_action_categories x
WHERE x.mnem = ?",
    },

    {
        name => 'DocLib Types',
        dir => 'DocLibTypes',
        extension => '\.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT dlt.xml_data.getClobVal()
FROM doclibmgr.document_library_types dlt
WHERE dlt.document_library_type = ?",
    },

    {
        name => 'Document Templates',
        dir => 'DocumentTemplates',
        extension => '\.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT dt.xml_data.getClobVal()
FROM decmgr.document_templates dt
WHERE dt.name = ?",
    },

    {
        name => 'File Folder Types',
        dir => 'FileFolderTypes',
        extension => '\.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT fft.xml_data.getClobVal()
FROM decmgr.file_folder_types fft
WHERE fft.file_folder_type = ?",
    },

    {
        name => 'Mapsets',
        dir => 'Mapsets',
        extension => '\.xml',
        remove_patterns => [ '\s', '<!--.\*-->' ],
        stmt => "
SELECT emm.metadata.getClobVal()
FROM envmgr.env_mapsets_metadata emm
WHERE emm.domain = ?",
    },
    );
}