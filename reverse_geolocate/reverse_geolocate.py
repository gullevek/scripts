#!/opt/local/bin/python3

# AUTHOR : Clemens Schwaighofer
# DATE   : 2018/2/20
# LICENSE: GPLv3
# DESC   : Set the reverse Geo location (name) from Lat/Long data in XMP files in a lightroom catalogue
#          * tries to get pre-set geo location from LR catalog
#          * if not found tries to get data from Google
#          * all data is translated into English with long vowl system (aka ou or oo is ō)
# MUST HAVE: Python XMP Toolkit (http://python-xmp-toolkit.readthedocs.io/)

import argparse
import glob, os, sys, re
# Note XMPFiles does not work with sidecar files, need to read via XMPMeta
from libxmp import XMPMeta, XMPError, consts
import sqlite3
import requests

##############################################################
### FUNCTIONS
##############################################################

# argparse helper
# call: writable_dir_folder
# checks if this is a writeable folder OR file
# AND it works on nargs *
class writable_dir_folder(argparse.Action):
    def __call__(self, parser, namespace, values, option_string = None):
        # we loop through list (this is because of nargs *)
        for prospective_dir in values:
            # if valid and writeable (dir or file)
            if os.access(prospective_dir, os.W_OK):
                # init new output array
                out = []
                # if we have a previous list in the namespace extend current list
                if type(namespace.xmp_sources) is list:
                    out.extend(namespace.xmp_sources)
                # add the new dir to it
                out.append(prospective_dir)
                # and write that list back to the self.dest in the namespace
                setattr(namespace, self.dest, out)
            else:
                raise argparse.ArgumentTypeError("writable_dir_folder: {0} is not a writable dir".format(prospective_dir))

# call: readable_dir
# custom define to check if it is a valid directory
class readable_dir(argparse.Action):
    def __call__(self, parser, namespace, values, option_string = None):
        prospective_dir=values
        if not os.path.isdir(prospective_dir):
            raise argparse.ArgumentTypeError("readable_dir:{0} is not a valid path".format(prospective_dir))
        if os.access(prospective_dir, os.R_OK):
            setattr(namespace,self.dest,prospective_dir)
        else:
            raise argparse.ArgumentTypeError("readable_dir:{0} is not a readable dir".format(prospective_dir))

# METHOD: reverseGeolocate
# PARAMS: latitude, longitude
# RETURN: dict with location, city, state, country, country code
#         if not fillable, entry is empty
#         google images lookup base settings
# SAMPLE: http://maps.googleapis.com/maps/api/geocode/json?latlng=35.6671355,139.7419185&sensor=false
def reverseGeolocate(longitude, latitude):
    # clean up long/lat
    # they are stored with N/S/E/W if they come from an XMP
    # format: Deg,Min.Sec[NSEW]
    # NOTE: lat is N/S, long is E/W
    # detect and convert
    latlong_re = re.compile('^(\d+),(\d+\.\d+)([NESW]{1})$')
    # dict for loop
    lat_long = {
        'longitude': longitude,
        'latitude': latitude
    }
    for element in lat_long:
        # match if it is exif GPS format
        m = latlong_re.match(lat_long[element])
        if m is not None:
            # convert from Degree, Min.Sec into float format
            lat_long[element] = float(m.group(1)) + (float(m.group(2)) / 60)
            # if S or W => inverse to negative
            if m.group(3) == 'S' or m.group(3) == 'W':
                lat_long[element] *= -1
    # sensor (why?)
    sensor = 'false'
    # request to google
    base = "http://maps.googleapis.com/maps/api/geocode/json?"
    params = "latlng={lon},{lat}&sensor={sensor}".format(lon = lat_long['longitude'], lat = lat_long['latitude'], sensor = sensor)
    url = "{base}{params}".format(base = base, params = params)
    response = requests.get(url)
    # sift through the response to get the best matching entry
    geolocation = {
        'CountryCode': '',
        'Country': '',
        'State': '',
        'City': '',
        'Location': ''
    }
    # first entry for type = premise
    for entry in response.json['results']:
        for sub_entry in entry:
            if sub_entry == 'types' and 'premise' in entry[sub_entry]:
                # print("Entry {}: {}".format(sub_entry, entry[sub_entry]))
                # print("Address {}".format(entry['address_components']))
                # type
                # -> country,
                # -> administrative_area (1),
                # -> locality,
                # -> sublocality (_level_1 or 2 first found)
                for addr in entry['address_components']:
                    # print("Addr: {}".format(addr))
                    # country code + country
                    if 'country' in addr['types'] and not country_code:
                        geolocation['CountryCode'] = addr['short_name']
                        geolocation['Country'] = addr['long_name']
                        # print("Code: {}, Country: {}".format(country_code, country))
                    # state
                    if 'administrative_area_level_1' in addr['types'] and not state:
                        geolocation['State'] = addr['long_name']
                        # print("State (1): {}".format(state))
                    if 'administrative_area_level_2' in addr['types'] and not state:
                        geolocation['State'] = addr['long_name']
                        # print("State (2): {}".format(state))
                    # city
                    if 'locality' in addr['types'] and not city:
                        geolocation['City'] = addr['long_name']
                        # print("City: {}".format(city))
                    # location
                    if 'sublocality_level_1' in addr['types'] and not location:
                        geolocation['Location'] = addr['long_name']
                        # print("Location (1): {}".format(location))
                    if 'sublocality_level_2' in addr['types'] and not location:
                        geolocation['Location'] = addr['long_name']
                        # print("Location (1): {}".format(location))
                    # if all failes try route
                    if 'route' in addr['types'] and not location:
                        geolocation['Location'] = addr['long_name']
                        # print("Location (R): {}".format(location))
    # return
    return geolocation

# METHOD: convertLatLongToDMS
# PARAMS: latLong in (-)N.N format, lat or long flag (else we can't set N/S)
# RETURN: Deg,Min.Sec(NESW) format
# DESC  : convert the LR format of N.N to the Exif GPS format
def convertLatLongToDMS(lat_long, is_latitude = False, is_longitude = False):
    # minus part before . and then multiply rest by 60
    degree = int(abs(lat_long))
    minutes = round((float(abs(lat_long)) - int(abs(lat_long))) * 60, 10)
    if is_latitude == True:
        direction = 'S' if int(lat_long) < 0 else 'N'
    elif is_longitude == True:
        direction = 'W' if int(lat_long) < 0 else 'E'
    else:
        direction = '(INVALID)'
    return "{},{}{}".format(degree, minutes, direction)

# wrapper functions for Long/Lat calls
def convertLatToDMS(lat_long):
    return convertLatLongToDMS(lat_long, is_latitude = True)
def convertLongToDMS(lat_long):
    return convertLatLongToDMS(lat_long, is_longitude = True)

# just for test long/lat regex
def longLatReg(longitude, latitude):
    # regex
    latlong_re = re.compile('^(\d+),(\d+\.\d+)([NESW]{1})$')
    # dict for loop
    lat_long = {
        'longitude': longitude,
        'latitude': latitude
    }
    for element in lat_long:
        # match if it is exif GPS format
        m = latlong_re.match(lat_long[element])
        if m is not None:
            # convert from Degree, Min.Sec into float format
            lat_long[element] = float(m.group(1)) + (float(m.group(2)) / 60)
            # if S or W => inverse to negative
            if m.group(3) == 'S' or m.group(3) == 'W':
                lat_long[element] *= -1
    return lat_long

##############################################################
### ARGUMENT PARSNING
##############################################################

parser = argparse.ArgumentParser(
    description = 'Reverse Geoencoding based on set Latitude/Longitude data in XMP files',
    # formatter_class=argparse.RawDescriptionHelpFormatter,
    epilog = 'Sample: (todo)'
)

# xmp folder (or folders), or file (or files)
# note that the target directory or file needs to be writeable
parser.add_argument('-x', '--xmp',
    required = True,
    nargs = '*',
    action = writable_dir_folder,
    dest = 'xmp_sources',
    metavar = 'XMP SOURCE FOLDER',
    help = 'The source folder or folders with the XMP files that need reverse geo encoding to be set. Single XMP files can be given here'
)

# LR database (base folder)
# get .lrcat file in this folder
parser.add_argument('-l', '--lightroom',
    # required = True,
    action = readable_dir,
    dest = 'lightroom_folder',
    metavar = 'LIGHTROOM FOLDER',
    help = 'Lightroom catalogue base folder'
)

# set behaviour override
# FLAG: default: only set not filled
# other: overwrite all or overwrite if one is missing, overwrite specifc field (as defined below)
# fields: Location, City, State, Country, CountryCode
parser.add_argument('-f', '--field',
    nargs = '*',
    type = str.lower, # make it lowercase for check
    choices = ['overwrite', 'location', 'city', 'state', 'country', 'countrycode'],
    dest = 'field_controls',
    metavar = 'FIELD CONTROLS',
    help = 'On default only set fields that are not set yet. Options are: Overwrite (write all new), Location, City, State, Country, CountryCode. Multiple can be given. If with overwrite the field will be overwritten if already set, else it will be always skipped'
)

# verbose args for more detailed output
parser.add_argument('-v', '--verbose',
    action = 'count',
    dest = 'verbose',
    help = 'Set verbose output level'
)

# debug flag
parser.add_argument('--debug', dest='debug', help = 'Set detailed debug output')

# read in the argumens
args = parser.parse_args()

##############################################################
### MAIN CODE
##############################################################

if args.debug:
    print("ACTION VARS: X: {}, L: {}, F: {}, V: {}".format(args.xmp_sources, args.lightroom_folder, args.field_controls, args.verbose))

# The XMP fields const lookup values
# XML/XMP
# READ:
# exif:GPSLatitude
# exif:GPSLongitude
# READ for if filled
# Iptc4xmpCore:Location
# photoshop:City
# photoshop:State
# photoshop:Country
# Iptc4xmpCore:CountryCode
xmp_fields = {
    'GPSLatitude': consts.XMP_NS_EXIF, # they are stored with N/E and other locations on the back if not N/E they need to be inverted *-1 for Google search
    'GPSLongitude': consts.XMP_NS_EXIF,
    'Location': consts.XMP_NS_IPTCCore,
    'City': consts.XMP_NS_Photoshop,
    'State': consts.XMP_NS_Photoshop,
    'Country': consts.XMP_NS_Photoshop,
    'CountryCode': consts.XMP_NS_IPTCCore
}
# non lat/long fields (for loc loops)
data_set_loc = ('Location', 'City', 'State', 'Country', 'CountryCode')
# one xmp data set
data_set = {
    'GPSLatitude': '',
    'GPSLongitude': '',
    'Location': '',
    'City': '',
    'State': '',
    'Country': '',
    'CountryCode': ''
}
# original set for compare (is constant unchanged)
data_set_original = {}
# cache set to avoid double lookups for identical Lat/Ling
data_cache = []
# error flag
error = 0
# use lightroom
use_lightroom = 0
# cursors & query
query = ''
cur = ''

# do lightroom stuff only if we have the lightroom folder
if args.lightroom_folder:
    # query string for lightroom DB check
    # Return sample
    # 1032|XT1R3587|1041|X-T1/|XT1R3587.RAF|1041|35.666922555555|139.746432277778|gps||Minato-ku|Tōkyō-to|Japan|JP
    query = 'SELECT Adobe_images.id_local, AgLibraryFile.baseName, AgLibraryFolder.pathFromRoot, AgLibraryFile.originalFilename, AgHarvestedExifMetadata.gpsLatitude, AgHarvestedExifMetadata.gpsLongitude, AgHarvestedIptcMetadata.locationDataOrigination, AgInternedIptcLocation.value as Location, AgInternedIptcCity.value as City, AgInternedIptcState.value as State, AgInternedIptcCountry.value as Country, AgInternedIptcIsoCountryCode.value as CountryCode '
    query += 'FROM AgLibraryFile, AgHarvestedExifMetadata, AgLibraryFolder, Adobe_images '
    query += 'LEFT JOIN AgHarvestedIptcMetadata ON Adobe_images.id_local = AgHarvestedIptcMetadata.image '
    query += 'LEFT JOIN AgInternedIptcLocation ON AgHarvestedIptcMetadata.locationRef = AgInternedIptcLocation.id_local '
    query += 'LEFT JOIN AgInternedIptcCity ON AgHarvestedIptcMetadata.cityRef = AgInternedIptcCity.id_local '
    query += 'LEFT JOIN AgInternedIptcState ON AgHarvestedIptcMetadata.stateRef = AgInternedIptcState.id_local '
    query += 'LEFT JOIN AgInternedIptcCountry ON AgHarvestedIptcMetadata.countryRef = AgInternedIptcCountry.id_local '
    query += 'LEFT JOIN AgInternedIptcIsoCountryCode ON AgHarvestedIptcMetadata.isoCountryCodeRef = AgInternedIptcIsoCountryCode.id_local '
    query += 'WHERE Adobe_images.rootFile = AgLibraryFile.id_local AND Adobe_images.id_local = AgHarvestedExifMetadata.image AND AgLibraryFile.folder = AgLibraryFolder.id_local '
    query += 'AND AgLibraryFile.baseName = ?'
    if args.debug:
        print("Query {}".format(query))

    # connect to LR database for reading
    # open the folder and look for the first lrcat file in there
    for file in os.listdir(args.lightroom_folder):
        if file.endswith('.lrcat'):
            lightroom_database = os.path.join(args.lightroom_folder, file)
            lrdb = sqlite3.connect(lightroom_database)
    if not lightroom_database or not lrdb:
        print("We could not find a lrcat file in the given lightroom folder: {}".format(args.lightroom_folder))
        # flag for end
        error = 1
    else:
        # set row so we can access each element by the name
        lrdb.row_factory = sqlite3.Row
        # set cursor
        cur = lrdb.cursor()
        use_lightroom = 1

# on error exit here
if error:
    sys.exit(1)

# init the XML meta for handling
xmp = XMPMeta()

# loop through the xmp_sources (folder or files) and read in the XMP data for LAT/LONG, other data
for xmp_file in args.xmp_sources:
    # if folder, open and loop
    # NOTE: we do check for folders in there, if there are we recourse traverse them

    # ******* TEST *******
    # for the XMP parse/read write test we only go on files now, no folders
    if not os.path.isdir(xmp_file):
        xmp_file_basename = os.path.splitext(os.path.split(xmp_file)[1])[0]
        print("Working on File: {} => {}".format(xmp_file, xmp_file_basename))
        # read in data from DB if we uave lightroom folder
        if use_lightroom:
            cur.execute(query, [xmp_file_basename])
            lrdb_row = cur.fetchone()
            print("LightroomDB: {} / {}".format(tuple(lrdb_row), lrdb_row.keys()))

        #### FOLDER
        # open file & read all into buffer
        with open(xmp_file, 'r') as fptr:
            strbuffer = fptr.read()
        # xmp part
        xmp.parse_from_str(strbuffer)
        for xmp_field in xmp_fields:
            data_set[xmp_field] = xmp.get_property(xmp_fields[xmp_field], xmp_field)
            print("{}:{} => {}".format(xmp_fields[xmp_field], xmp_field, data_set[xmp_field]))
        data_set_original = data_set.copy()

        # debug output bla
        print("Long/Lat: {}".format(longLatReg(data_set['GPSLongitude'], data_set['GPSLatitude'])))
        print("Inp Long/Lat: {}".format(longLatReg('35,40.0153533333S', '139,44.7859366667W')))
        print("Convert Long -> DMS: {}, Lat -> DMS: {}".format(convertLatLongToDMS(139.74643227777833, is_longitude = True), convertLatLongToDMS(35.666922555555, is_latitude = True)))
        print("Convert Long -> DMS: {}, Lat -> DMS: {}".format(convertLongToDMS(-139.74643227777833), convertLatToDMS(-35.666922555555)))
        # TEST RUN
        # check if LR exists and use this to compare to XMP data
        # is LR GPS and no XMP GPS => use LR and set XMP
        # same for location names
        # if missing in XMP but in LR -> set in XMP
        # if missing in both do lookup in Google
        if use_lightroom:
            if lrdb_row['gpsLatitude'] and not data_set['GPSLatitude']:
                # we need to convert to the Degree,Min.sec[NSEW] format
                data_set['GPSLatitude'] = convertLatToDMS(lrdb_row['gpsLatitude'])
            if lrdb_row['gpsLongitude'] and not data_set['GPSLongitude']:
                data_set['GPSLongitude'] = convertLongToDMS(lrdb_row['gpsLongitude'])
            # now check Location, City, etc
            for loc in data_set_loc:
                if lrdb_row[loc] and not data_set[loc]:
                    data_set[loc] = lrdb_row[loc]
        # base set done, now check if there is anything unset in the data_set, if yes do a lookup in google
        has_unset = 0
        for loc in data_set_loc:
            if not data_set[loc]:
                has_unset = 1
        if has_unset:
            google_location = reverseGeolocate(latitude = data_set['GPSLatitude'], longitude = data_set['GPSLongitude'])
            # overwrite sets (note options check here)
            print("Google Location: {}".format(google_location))


        # xmp.set_property(consts.XMP_NS_IPTCCore, 'Location', 'Yaguchi')
        # print("Iptc4xmpCore:Location {} => {}".format(consts.XMP_NS_IPTCCore, xmp.get_property(consts.XMP_NS_IPTCCore, 'Location')))
        # # write that back to temp file
        # # print("ALL {}".format(xmp.serialize_to_str(omit_packet_wrapper=True)))
        # with open('/Users/gullevek/temp/XMP/sample/temp_write_script.xmp', 'w') as fptr:
        #     print("Write to test xmp file")
        #     # omit the xpacket header part, we don't need that in sidecar files
        #     fptr.write(xmp.serialize_to_str(omit_packet_wrapper=True))
    else:
        print("TEST Skip {} because it is a folder.".format(xmp_file))

# close DB connection
lrdb.close()

# __END__