/*
 * cCSVParse, a small CVS file parser
 *
 * © 2007-2009 Michael Stapelberg and contributors
 * http://michael.stapelberg.de/
 *
 * This source code is BSD-licensed, see LICENSE for the complete license.
 *
 */
#include <stdio.h>
#include <string.h>
#include <fcntl.h>
#include <stdbool.h>
#include <unistd.h>
#include <stdint.h>
#include <assert.h>

#import "parseCSV.h"

/* Macros for determining if the given character is End Of Line or not */
#define EOL(x) ((*(x) == '\r' || *(x) == '\n') && *(x) != '\0')
#define NOT_EOL(x) (*(x) != '\0' && *(x) != '\r' && *(x) != '\n')

char possibleDelimiters[4] = ",;\t\0";
//char possibleDelimiters[5] = ",;|\t\0";

/*
 * replacement for strstr() which does only check every char instead
 * of complete strings
 * Warning: Do not call it with haystack == NULL || needle == NULL!
 *
 */
static char *cstrstr(const char *haystack, const char needle) {
	char *it = (char*)haystack;
	while (*it != '\0') {
		if (*it == needle)
			return it;
		it++;
	}
	return NULL;
}

char searchDelimiter(char *textp) {
	char delimiter = '\n';
	
	// ...we assume that this is the header which also contains the separation character
	while (NOT_EOL(textp) && cstrstr(possibleDelimiters, *textp) == NULL)
		textp++;
	
	// Check if a delimiter was found and set it
	if (NOT_EOL(textp)) {
		delimiter = *cstrstr((const char*)possibleDelimiters, *textp);
		return delimiter;
	}
	else {
		return 0;
	}
}

/*
 * Copies a string without beginning- and end-quotes if there are
 * any and returns a pointer to the string or NULL if malloc() failed
 *
 */
NSString * parseString(char *textp, char *laststop, NSStringEncoding encoding) {
	NSUInteger stringSize = (size_t)(textp - laststop);
	
	if (*laststop == '\"' && *(laststop+1) != '\0' && *(laststop + stringSize - 1) == '\"') {
		laststop++;
		stringSize -= 2;
	}
	
	NSMutableString *tempString = [[NSMutableString alloc] initWithBytes:laststop
																  length:stringSize
																encoding:encoding];
	
	[tempString replaceOccurrencesOfString:@"\"\"" 
								withString:@"\"" 
								   options:0
									 range:NSMakeRange(0, [tempString length])];
	
	return [tempString autorelease];
}


@implementation CSVParser {
	int _fileHandle;
	size_t _bufferSize;
	char _delimiter;
	char _endOfLine[3];
	NSStringEncoding _encoding;
	BOOL _verbose;
	BOOL _fileMode;
	NSData *_data;
}

-(void)setData:(NSData *)value {
    if (_data != value) {
        [_data release];
        _data = [value copy];
    }
}

-(id)init {
	self = [super init];
	if (self) {
		// Set default _bufferSize
		_bufferSize = 2048;
		// Set fileHandle to an invalid value
		_fileHandle = 0;
		// Set delimiter to 0
		_delimiter = '\0';
		// Set endOfLine to empty
		_endOfLine[0] = '\0';
		_endOfLine[1] = '\0';
		_endOfLine[2] = '\0';
		// Set default encoding
		_encoding = NSISOLatin1StringEncoding;
		// Set default verbosity
		_verbose = NO;
		
		_data = nil;
	}
	return self;
}

-(void)dealloc {
	[self closeFile];
	
	[self setData:nil]; 
	
	[super dealloc];
}




/*
 * Gets the CSV-delimiter from the given filename using the first line
 * which should be the header-line. Returns 0 on error.
 *
 */
-(char)autodetectDelimiter {
	char buffer[_bufferSize+1];

	NSInteger n;
	
	if (_fileMode) {
		// Seek to the beginning of the file
		lseek(_fileHandle, 0, SEEK_SET);

		// Fill the buffer
		n = read(_fileHandle, buffer, _bufferSize);
	}
	else {
		assert(sizeof(uint8_t) == sizeof(char));
		NSInputStream *dataStream = [NSInputStream inputStreamWithData:_data];
		[dataStream open];
		
		n = [dataStream read:(uint8_t *)buffer maxLength:_bufferSize];
		
		[dataStream close];
	}

	
	if (n > 0) {
		char *textp = buffer;
		return searchDelimiter(textp);
	}

	return 0;
}

-(NSMutableArray *)parseInto:(NSMutableArray *)csvContent
{
	NSMutableArray *csvLine = [NSMutableArray array];
	NSInputStream *dataStream = nil;
	

	ssize_t n = 1;
	size_t diff;
	NSUInteger lastColumnCount = 0;
	unsigned int quoteCount = 0;
	bool firstLine = true;
	bool addCurrentLineStartNew = false;
	size_t bufferCapacity = _bufferSize + 1;
	size_t necessaryCapacity = 0;
	char *buffer = malloc(sizeof(char) * bufferCapacity);
	char *textp = NULL, *lastStop = NULL, *lineStart = NULL, *lastLineBuffer = NULL;
	
	if (_fileMode) {
		lseek(_fileHandle, 0, SEEK_SET);
	}
	else {
		assert(sizeof(uint8_t) == sizeof(char));
		dataStream = [NSInputStream inputStreamWithData:_data];
		[dataStream open];
	}

	while (n > 0) {
		
		if (lastLineBuffer != NULL) {
			
			if (strlen(lastLineBuffer) == _bufferSize) {
				// CHANGEME: Recover from this
				[csvContent removeAllObjects];
				[csvContent addObject:[NSMutableArray arrayWithObject: @"ERROR: Buffer too small"]];
				return csvContent;
			}
			
			// Take care of the quotes in lastLineBuffer!
			textp = lastLineBuffer;
			while (*textp != '\0') {
				if (*textp == '\"')
					quoteCount++;
				textp++;
			}
			
			// Copy lastLineBuffer to the beginning of the buffer
			strcpy(buffer, lastLineBuffer);
			diff = strlen(lastLineBuffer);
			
			// Increase the buffer size so that the buffer can hold 
			// both lastLineBuffer and a block of bufferSize
			necessaryCapacity = diff + _bufferSize;
			if (bufferCapacity < necessaryCapacity) {
				buffer = realloc(buffer, necessaryCapacity);
				if (buffer == NULL) {
					[csvContent removeAllObjects];
					[csvContent addObject:[NSMutableArray arrayWithObject: @"ERROR: Could not allocate bytes for buffer"]];
					return csvContent;
				}
				bufferCapacity = necessaryCapacity;
			}
			
			lastLineBuffer = NULL;
			
		} 
		else {
			diff = 0;
		}
		
		if (_fileMode) {
			n = read(_fileHandle, (buffer + diff), _bufferSize);
		}
		else {
			n = [dataStream read:(uint8_t *)(buffer + diff) maxLength:_bufferSize];
		}

		if (n <= 0)
			break;
		
		// Terminate buffer correctly
		if ((diff+n) <= (_bufferSize + diff))
			buffer[diff+n] = '\0';
		
		textp = (char *)buffer;
		
		while (*textp != '\0') {
			// If we don't have a delimiter yet and this is the first line...
			if (firstLine && _delimiter == '\0') {
				//firstLine = false;
				
				// Check if a delimiter was found and set it
				_delimiter = searchDelimiter(textp);
				if (_delimiter != 0) {
					if (_verbose) {
						printf("delim is %c / %d :-)\n", _delimiter, _delimiter);
					}
					//while (NOT_EOL(textp))
					//	textp++;
				}
				
				textp = (char*)buffer;
			} 
			
			if (strlen(textp) > 0) {
				// This is data
				lastStop = textp;
				lineStart = textp;
				
				// Parsing is split into parts till EOL
				while (NOT_EOL(textp) || (*textp != '\0' && (quoteCount % 2) != 0)) {
					// If we got two quotes and a delimiter before and after, this is an empty value
					if (*textp == '\"') { 
						if (*(textp+1) == '\"') {
							// we'll just skip this
							textp++;
						} 
						else {
							quoteCount++;
						}
					} 
					else if (*textp == _delimiter && (quoteCount % 2) == 0) {
						// This is a delimiter which is not between an unmachted pair of quotes
						[csvLine addObject:parseString(textp, lastStop, _encoding)];
						lastStop = textp + 1;
					}
					
					// Go to the next character
					textp++;
				}
				
				addCurrentLineStartNew = false;
				
				if (lastStop == textp && *(textp-1) == _delimiter) {
					[csvLine addObject:@""];
					
					addCurrentLineStartNew = true;
				}
				else if (lastStop != textp && (quoteCount % 2) == 0) {
					[csvLine addObject:parseString(textp, lastStop, _encoding)];
					
					addCurrentLineStartNew = true;
				} 
				
				if (addCurrentLineStartNew) {
					if ((int)(buffer + _bufferSize + diff - textp) > 0) {
						lineStart = textp + 1;
						[csvContent addObject:csvLine];
						lastColumnCount = [csvLine count];
					}
					csvLine = [NSMutableArray arrayWithCapacity:lastColumnCount]; // convenience methods always autorelease
				}
				
				if ((*textp == '\0' || (quoteCount % 2) != 0) && lineStart != textp) {
					lastLineBuffer = lineStart;
					csvLine = [NSMutableArray arrayWithCapacity:lastColumnCount];
				}
			}
			
			if (firstLine) {
				if ( (lineStart != NULL) && (lineStart-1 >= buffer) && EOL(lineStart-1) ) {
					_endOfLine[0] = *(lineStart-1);

					if ( EOL(lineStart) ) {
						_endOfLine[1] = *(lineStart);
					}
				}
				
				firstLine = false;
			}
			
			while (EOL(textp))
				textp++;
		}
	}
	
	free(buffer);
	buffer = NULL;

	if (!_fileMode) {
		[dataStream close];
	}

	return csvContent;
}

/*
 * Parses the CSV-file with the given filename and return the result as an
 * NSMutableArray.
 *
 */
-(NSMutableArray*)parseFile {
	if (_fileHandle <= 0)  return [NSMutableArray array];
	
	NSMutableArray *csvContent = [NSMutableArray array];

	return [self parseInto:csvContent];

}

/*
 * Parses the current data as CSV and return the result as an
 * NSMutableArray.
 *
 */
-(NSMutableArray *)parseData
{
	if (_data == nil)  return nil;
	
	NSMutableArray *csvContent = [NSMutableArray array];
	
	_fileMode = NO;
	
	
	[self parseInto:csvContent];
	
	return csvContent;
}

/*
 * Parses the data as CSV and return the result as an
 * NSMutableArray.
 *
 */
-(NSMutableArray *)parseData:(NSData *)data
{
	NSMutableArray *csvContent = [NSMutableArray array];

	_fileMode = NO;
	
	if (data != nil) {
		[self setData:data];

		[self parseInto:csvContent];

		return csvContent;
	}
	else {
		return csvContent;
	}

	
}

-(BOOL)openFile:(NSString*)fileName {
	_fileMode = YES;
	_fileHandle = open([fileName UTF8String], O_RDONLY);
	return (_fileHandle > 0);
}

-(void)closeFile {
	if (_fileHandle > 0) {
		close(_fileHandle);
		_fileHandle = 0;
	}
}

-(NSString *)delimiterString {
	char delimiterCString[2] = {'\0', '\0'};
	delimiterCString[0] = _delimiter;
    return [NSString stringWithCString:delimiterCString encoding:_encoding];
}

-(NSString *)endOfLine {
    return [NSString stringWithCString:_endOfLine encoding:_encoding];
}

@end
