from optparse import OptionParser

parser = OptionParser()
parser.add_option("-u", "--username", dest="username", default="xviewmgr",
                  help="the user to connect as")

parser.add_option("-p", "--password", dest="password",
                  help="the password of the user")

parser.add_option("-r", "--port", dest="port", default="1521",
                  help="the port to connect to")

parser.add_option("-o", "--host", dest="host",
                  help="the host to connect to")

parser.add_option("-s", "--sid", dest="sid",
                  help="the Oracle System ID to connect to")

parser.add_option("-d", "--directory", dest="directory",
                  help="the directory to compare with the database")

(options, args) = parser.parse_args()

if len(args) != 1:
    parser.error("incorrect number of arguments")

import argparse

parser = argparse.ArgumentParser(description='Process some integers.')
parser.add_argument('username', metavar='u', type=string, nargs='+',
                   help='an integer for the accumulator')
parser.add_argument('--sum', dest='accumulate', action='store_const',
                   const=sum, default=max,
                   help='sum the integers (default: find the max)')

args = parser.parse_args()
print( args.accumulate(args.integers) )