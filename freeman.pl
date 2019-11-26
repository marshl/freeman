###############################################################################
#
# Fox REconciliation Enterprise MANager
#
# "The right man in the wrong place can make all the difference in the world."
#
####

# Strict forbids symbolic references, use of undeclared variables and "Poetry optimisation" (uses of bareword identifiers)
use strict;

# Warnings promotes most hidden warnings to visible, ushc as useless use of variables in void context, or accessing null scalars
use warnings;

# Perl database interface module
use DBI;

# Used to dump the entire contents of a variable and all nested objects as a string
use Data::Dumper;

# English replaces ugly punctuation variables, such as $/, with proper names
use English qw(-no_match_vars);
use File::Basename;
use File::Find;
use File::Spec;

# Verify that the exact number of arguments is given (an array, which all begin with @, in numerical context is the length of the array)
die "Usage: freeman.pl code_source_dir host port sid username password\n" if @ARGV != 6;

# Declare a variable for each item in the argument list
my ($code_source_dir, $host, $port, $sid, $username, $password) = @ARGV;

# Verify that the CodeSource directory exists
die "Invalid folder $code_source_dir" if not -d $code_source_dir;

# Connect to the database. Don't print warnings or errors, as they will be handled during normal program flow. Also expand the read length to a safe size
# Hashes in perl are defined using { key => value }
# Most perl functions return a false value if they fail. If you "or" the result with the die function, then die will be called if the function call fails
# Die is similar to abort(), but also prints an error message and a stack trace if called in a module
my $database_handle = DBI->connect("dbi:Oracle:host=$host;port=$port;sid=$sid;", $username, $password, { PrintError => 0, PrintWarn => 0, LongReadLen => 512 * 1024 })
    or die "Error connecting to DB: $DBI::errstr";

compare_directories($database_handle, $code_source_dir);
compare_patches($database_handle, $code_source_dir);
compare_database_source($database_handle, $code_source_dir);
$database_handle->disconnect();

sub compare_directories {

    # Parameters are stored in the @ARG array, and can be assigned from in bulk
    my ($database_handle, $code_source_dir) = @ARG;

    my @directory_types = get_directory_types();

    # Loops can be labelled and then specified when using next (continue), last (break) or redo
    # a foreach loop iterates over the @array and stores the current value within the $scalar
    DIRECTORY_TYPE:
    foreach my $directory_type (@directory_types) {
        print "\nComparing $directory_type->{'name'}\n";

        # Create an absolute path to the directory in CodeSource
        # $directory_type is a reference to a hash, so -> dereferences it, then {'key'} accesses the hash
        my $directory_path = File::Spec->catfile($code_source_dir, $directory_type->{'directory'});

        # Verify that the directory exists
        if (not -d $directory_path) {
            print "Directory not found: $directory_path\n";
            next DIRECTORY_TYPE;
        }

        # Prepare the statement for the directory type defined below (or die with the error from the db handle)
        my $statement = $database_handle->prepare($directory_type->{'statement'})
            or die $database_handle->errstr;

        # find() uses an anonyomous sub to find all files that match the extension of the directory type
        my @file_list;
        find(
            sub {
                if (m/^.+?$directory_type->{'extension'}$/xs) {
                    # add file name to file list 
                    push @file_list, $File::Find::name;
                }
            },
            $directory_path
        );

        FULLPATH:
        foreach my $fullpath (@file_list) {
            my $filename = basename($fullpath);
            my ($without_extension) = fileparse($fullpath, qr/[.][^.]*/x);

            $statement->execute($without_extension)
                or die "Error executing statement: $statement->errstr()";

            my $filedata = $statement->fetchrow();

            if ($statement->rows > 1) {
                print "Too many records found for $filename\n";
                next FULLPATH;
            }

            if ($statement->rows == 0) {
                print "New File: $filename\n";
                next FULLPATH;
            }

            my $local_file_content = read_file_text($fullpath);
            my $patterns = $directory_type->{'remove_patterns'};

            # For each pattern in the directory type pattern list
            # remove any text that matches that pattern
            foreach my $pattern (@{$patterns}) {
                $local_file_content =~ s/$pattern//g;
                $filedata =~ s/$pattern//g;
            }

            # ne is the string equivalent of != 
            # in perl == is used for numerical comparison
            if ($local_file_content ne $filedata) {
                print "Modified: $filename\n";
            }
        }
    }
}

sub compare_patches {
    my ($database_handle, $code_source_dir) = @ARG;

    print "\nChecking patch runs\n";

    my $patch_directory = File::Spec->catfile($code_source_dir, 'DatabasePatches');

    my @patch_list;
    find(
        sub {
            if (m/^.+?\.sql$/) {
                push @patch_list, $File::Find::name;
            }
        },
        $patch_directory
    );

    # <<"QUERY_END" is here-doc, a way to break a string over multiple lines (similar to the Oracle q quote)
    my $statement = $database_handle->prepare(<<"QUERY_END"
SELECT COUNT(*)
FROM promotemgr.patch_runs pr
WHERE pr.patch_label = ?
AND pr.patch_number = ?
AND pr.ignore_flag IS NULL
QUERY_END
    ) or die $database_handle->errstr;

    PATCH:
    foreach my $patch (@patch_list) {
        my $filename = basename($patch);

        # =~ performs a regex match on the lhs using the regex on the rhs (regexes are defined using slashes /.+?/)
        if (not $filename =~ /^(\D+?)(\d+?) *\(.+?\)\.sql/) {
            print "$filename is not a valid patch naming format.\n";
            next PATCH;
        }

        # Regex grouping are stored in the globals $1 though $9 
        # $1 => patch label, $2 => patch description (see regex above)
        $statement->execute($1, $2)
            or die "Error executing statement: $statement->errstr()";

        # if the patch doesn't already exist (i.e.)
        my $count = $statement->fetchrow();
        if ($count == 0) {
            print "New Patch: $filename\n";
        }
    }
}

sub compare_database_source {
    my ($database_handle, $code_source_dir) = @ARG;

    print "\nComparing packages:\n";

    my $source_directory = File::Spec->catfile($code_source_dir, 'DatabaseSource');

    if (not $database_handle->do(<<"QUERY_END"
CREATE USER freemanmgr IDENTIFIED BY "password"
QUERY_END
    )) {
        # ORA-01920: user name 'string' conflicts with another user or role name 
        if ($database_handle->err == 1920) {
            print "FREEMANMGR already exists, and will not be recreated.\n";
        }
        else {
            die $database_handle->errstr;
        }
    }

    my @file_list;
    find(
        sub {
            if (m/^.+?\.(pkb|pks)$/) {
                push @file_list, $File::Find::name;
            }
        },
        $source_directory
    );

    my $statement = $database_handle->prepare(<<"QUERY_END"
SELECT COUNT(*)
FROM dba_source lhs
LEFT JOIN all_source rhs
ON lhs.type = rhs.type
AND rhs.name = lhs.name
AND rhs.line = lhs.line
AND rhs.owner = ?
WHERE lhs.type = ?
AND lhs.owner = 'FREEMANMGR'
AND lhs.name = ?
AND lhs.text NOT LIKE '/%' -- For some reason the temporary package header can have a / on the last line
AND ( rhs.line IS NULL
    OR REGEXP_REPLACE( lhs.text, '\\s', '') != REGEXP_REPLACE( rhs.text, '\\s', '') )
QUERY_END
    ) or die $database_handle->errstr;

    # %hash is the way to define a perl hash, one of the three fundamental perl types (basically a dictionary)
    my %file_extensions = ('.pks' => 'PACKAGE', '.pkb' => 'PACKAGE BODY');

    PACKAGE:
    for my $fullpath (@file_list) {
        # keys returns the keys in a hash as an unsorted array
        my ($filename, $directory, $extension) = fileparse($fullpath, keys %file_extensions);
        my $file_content = read_file_text($fullpath);
        my $object_type = $file_extensions{$extension};

        if (not $file_content =~ /CREATE OR REPLACE.+?([^.\s"]+)"?\."?([^.\s"]+)/) {
            print "$filename$extension did not match standard creation syntax.\n";
            next PACKAGE;
        }

        my $schema_name = uc $1;
        my $object_name = uc $2;

        # An s/1/2/ regex match replaces instances of 1 with 2
        $file_content =~ s/(CREATE OR REPLACE.+?)([^.\s]+)\.([^.\s]+)/${1}FREEMANMGR.$3/;

        if (not $database_handle->do($file_content)) {

            # ORA-24344 is expected (Package compiled with compilation errors)
            if ($database_handle->err != 24344) {
                die $database_handle->errstr;
            }
        }

        $statement->execute($schema_name, $object_type, $object_name)
            or die $database_handle->errstr;

        my ($linecount) = $statement->fetchrow();
        if ($linecount != 0) {
            print "Modified: $fullpath\n";
        }
    }

    $database_handle->do("DROP USER freemanmgr CASCADE")
        or die $database_handle->errstr;
}

# Read and return all text of the given file
sub read_file_text {
    my ($filename) = @ARG;
    open(my $filehandle, '<', $filename) or die "Could not open file $filename: $OS_ERROR";

    # Remove the input record separator...
    local $INPUT_RECORD_SEPARATOR = undef;

    # ... so when a single line is read, the entire file is captured
    # <$filehandle> reads a single line from a handle. 
    # It is most commonly seen as the condition for a while loop to process the file one line at a time
    my $filedata = <$filehandle>;
    close $filehandle;
    return $filedata;
}

sub get_directory_types {

    my $whitespace_regex = '\s';
    my $js_regex = '\/[*].+?[*]\/';
    my $xml_regex = '<!--.*-->';

    # A list of directory types, each being a hash of information
    return(
        {
            name            => 'DocLib Types',
            directory       => 'DocLibTypes',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT dlt.xml_data.getClobVal()
FROM doclibmgr.document_library_types dlt
WHERE dlt.document_library_type = ?
QUERY_END
        },

        {
            name            => 'Document Templates',
            directory       => 'DocumentTemplates',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT dt.xml_data.getClobVal()
FROM decmgr.document_templates dt
WHERE dt.name = ?
QUERY_END
        },

        {
            name            => 'File Folder Types',
            directory       => 'FileFolderTypes',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT fft.xml_data.getClobVal()
FROM decmgr.file_folder_types fft
WHERE fft.file_folder_type = ?
QUERY_END
        },

        {
            name            => 'Fox5Modules - JavaScript',
            directory       => 'Fox5Modules',
            extension       => '\.js',
            remove_patterns => [ $whitespace_regex, $js_regex ],
            statement       => <<"QUERY_END"
SELECT data
FROM envmgr.fox_components_fox5 fc5
WHERE fc5.name = 'js/' || ?
QUERY_END
        },

        {
            name            => 'Fox5Modules - Modules',
            directory       => 'Fox5Modules',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT data
FROM envmgr.fox_components_fox5 fc5
WHERE fc5.name = ?
QUERY_END
        },

        {
            name            => 'FoxModules - Modules',
            directory       => 'FoxModules',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT fc.data FROM envmgr.fox_components fc
WHERE fc.type = 'module'
AND fc.name = ?
QUERY_END
        },

        {
            name            => 'Mapsets',
            directory       => 'Mapsets',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT emm.metadata.getClobVal()
FROM envmgr.env_mapsets_metadata emm
WHERE emm.domain = ?
QUERY_END
        },

        {
            name            => 'NavBar Action Groups',
            directory       => 'NavBarActionGroups',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT x.xml_data.getClobVal()
FROM envmgr.nav_bar_action_groups x
WHERE x.mnem = ?
QUERY_END
        },

        {
            name            => 'Navbar Categories',
            directory       => 'NavBarActionCategories',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT x.xml_data.getClobVal()
FROM envmgr.nav_bar_action_categories x
WHERE x.mnem = ?
QUERY_END
        },

        {
            name            => 'Port Folder Types',
            directory       => 'PortalFolderTypes',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT pft.xml_data.getClobVal()
FROM decmgr.portal_folder_types pft
WHERE pft.portal_folder_type = ?
QUERY_END
        },

        {
            name            => 'Report Definitions',
            directory       => 'ReportDefinitions',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT rd.xml_data.getClobVal()
FROM reportmgr.report_definitions rd
WHERE rd.domain = ?
QUERY_END
        },

        {
            name            => 'Resource Types',
            directory       => 'ResourceTypes',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT rt.xml_data.getClobVal()
FROM decmgr.resource_types rt
WHERE rt.res_type = ?
QUERY_END
        },

        {
            name            => 'Tally Types',
            directory       => 'TallyTypes',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT tt.xml_data.getClobVal()
FROM bpmmgr.tally_types tt
WHERE tt.tally_type = ?
QUERY_END
        },

        {
            name            => 'Work Request Types',
            directory       => 'ApplicationMetadata\\WorkRequestTypes',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT wrt.xml_data.getClobVal()
FROM iconmgr.work_request_types wrt
WHERE wrt.mnem = ?
QUERY_END
        },

        {
            name            => 'WUA Preference Categories',
            directory       => 'WUAPreferenceCategories',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT wpc.xml_data.getClobVal()
FROM securemgr.wua_preference_categories wpc
WHERE wpc.category_name = ?
QUERY_END
        },

        {
            name            => 'Xview Definitions',
            directory       => 'XviewDefinitions',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT x.xview_metadata.getClobVal()
FROM xviewmgr.xview_definition_metadata x
WHERE x.file_name = ? || '.xml'
QUERY_END
        },

        {
            name            => 'Xview 2 Definitions',
            directory       => 'Xview2Definitions',
            extension       => '\.xml',
            remove_patterns => [ $whitespace_regex, $xml_regex ],
            statement       => <<"QUERY_END"
SELECT x.xview_metadata_formatted
FROM xviewmgr.xview2_definition_metadata x
WHERE x.file_name = ? || '.xml'
QUERY_END
        },

    );
}