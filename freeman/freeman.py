#!/usr/bin/env python2
import argparse
import CX_Oracle

parser = argparse.ArgumentParser()
parser.add_argument("--username", default="xviewmgr",
                  help="the user to connect as")

parser.add_argument("--password", help="the password of the user")

parser.add_argument("--port", default="1521",
                  help="the port to connect to")

parser.add_argument("--host", help="the host to connect to")

parser.add_argument("--sid", help="the Oracle System ID to connect to")

parser.add_argument("--directory", help="the CodeSource directory to compare with the database")

args = parser.parse_args()

class FolderDefinition:
    def __init__(self, directory, extension, loadstatement):
        self.directory = directory;
        self.extension = extension;
        self.loadstatement = loadstatement;

folder_definitions = [ FolderDefinition("ResourceTypes", "*.xml",
"""SELECT rt.xml_data.getClobVal()
FROM decmgr.resource_types rt
WHERE rt.res_type = REPLACE( :file_name, '.xml', '' )""") ]

