//
//  TAASErrorResponse.h
//  TAAS-proxy
//
//  Created by Marshall Rose on 5/9/14.
//  Copyright (c) 2014 The Thing System. All rights reserved.
//

#import "HTTPDataResponse.h"


@interface TAASErrorResponse : HTTPDataResponse

- (id)initWithStatusCode:(int)statusCode andBody:(NSString *)body;

@end
