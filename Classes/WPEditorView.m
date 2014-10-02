#import "WPEditorView.h"

#import "UIWebView+GUIFixes.h"
#import "HRColorUtil.h"
#import "WPEditorField.h"
#import "ZSSTextView.h"

typedef void(^WPEditorViewCallbackParameterProcessingBlock)(NSString* parameterName, NSString* parameterValue);
typedef void(^WPEditorViewNoParamsCompletionBlock)();

static NSString* const kDefaultCallbackParameterSeparator = @"~";
static NSString* const kDefaultCallbackParameterComponentSeparator = @"=";

static NSString* const kWPEditorViewFieldTitleId = @"zss_field_title";
static NSString* const kWPEditorViewFieldContentId = @"zss_field_content";

@interface WPEditorView () <UITextViewDelegate, UIWebViewDelegate>

#pragma mark - Editing state
@property (nonatomic, assign, readwrite, getter = isEditing) BOOL editing;

#pragma mark - Selection
@property (nonatomic, strong, readwrite) NSString *selectedLinkURL;
@property (nonatomic, strong, readwrite) NSString *selectedLinkTitle;
@property (nonatomic, strong, readwrite) NSString *selectedImageURL;
@property (nonatomic, strong, readwrite) NSString *selectedImageAlt;

#pragma mark - Subviews
@property (nonatomic, strong, readwrite) ZSSTextView *sourceView;
@property (nonatomic, strong, readonly) UIWebView* webView;

#pragma mark - Operation queues
@property (nonatomic, strong, readwrite) NSOperationQueue* editorInteractionQueue;

#pragma mark - Editor loading support
@property (nonatomic, copy, readwrite) NSString* preloadedHTML;

#pragma mark - Fields
@property (nonatomic, weak, readwrite) WPEditorField* focusedField;

@end

@implementation WPEditorView

#pragma mark - NSObject

- (void)dealloc
{
    [self stopObservingKeyboardNotifications];
}

#pragma mark - UIView

- (instancetype)initWithFrame:(CGRect)frame
{
	self = [super initWithFrame:frame];
	
	if (self) {
		CGRect childFrame = frame;
		childFrame.origin = CGPointZero;
		
		[self createSourceViewWithFrame:childFrame];
		[self createWebViewWithFrame:childFrame];
		[self setupHTMLEditor];
	}
	
	return self;
}

- (void)willMoveToSuperview:(UIView *)newSuperview
{
    if (!newSuperview) {
        [self stopObservingKeyboardNotifications];
    } else {
        [self startObservingKeyboardNotifications];
    }
}

#pragma mark - Init helpers

- (void)createSourceViewWithFrame:(CGRect)frame
{
	NSAssert(!_sourceView, @"The source view must not exist when this method is called!");
	
	_sourceView = [[ZSSTextView alloc] initWithFrame:frame];
	_sourceView.hidden = YES;
	_sourceView.autocapitalizationType = UITextAutocapitalizationTypeNone;
	_sourceView.autocorrectionType = UITextAutocorrectionTypeNo;
	_sourceView.autoresizingMask =  UIViewAutoresizingFlexibleHeight;
	_sourceView.autoresizesSubviews = YES;
	_sourceView.delegate = self;
	
	[self addSubview:_sourceView];
}

- (void)createWebViewWithFrame:(CGRect)frame
{
	NSAssert(!_webView, @"The web view must not exist when this method is called!");
	
	_webView = [[UIWebView alloc] initWithFrame:frame];
	_webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
	_webView.delegate = self;
	_webView.scalesPageToFit = YES;
	_webView.dataDetectorTypes = UIDataDetectorTypeNone;
    _webView.backgroundColor = [UIColor whiteColor];
    _webView.scrollView.bounces = NO;
    _webView.usesGUIFixes = YES;
    _webView.keyboardDisplayRequiresUserAction = NO;
    _webView.scrollView.delegate = self;
	
	[self addSubview:_webView];
}

- (void)setupHTMLEditor
{
	_editorInteractionQueue = [[NSOperationQueue alloc] init];
	
	__block NSString* htmlEditor = nil;
	__weak typeof(self) weakSelf = self;
	
	NSBlockOperation* loadEditorOperation = [NSBlockOperation blockOperationWithBlock:^{
		htmlEditor = [self editorHTML];
	}];
	
    NSBlockOperation* editorDidLoadOperation = [NSBlockOperation blockOperationWithBlock:^{
        __strong typeof(weakSelf) strongSelf = weakSelf;

        if (strongSelf) {
            NSURL* const kBaseURL = [NSURL URLWithString:@"http://"];
            
            [strongSelf.webView loadHTMLString:htmlEditor baseURL:kBaseURL];
        }
    }];
	
	[loadEditorOperation setCompletionBlock:^{
		
		[[NSOperationQueue mainQueue] addOperation:editorDidLoadOperation];
	}];
	
	[_editorInteractionQueue addOperation:loadEditorOperation];
}

- (NSString*)editorHTML
{
	NSString *filePath = [[NSBundle mainBundle] pathForResource:@"editor" ofType:@"html"];
	NSData *htmlData = [NSData dataWithContentsOfFile:filePath];
	NSString *htmlString = [[NSString alloc] initWithData:htmlData encoding:NSUTF8StringEncoding];
	NSString *jQueryMobileEventsPath = [[NSBundle mainBundle] pathForResource:@"jquery.mobile-events.min" ofType:@"js"];
	NSString *jQueryMobileEvents = [[NSString alloc] initWithData:[NSData dataWithContentsOfFile:jQueryMobileEventsPath] encoding:NSUTF8StringEncoding];
	NSString *source = [[NSBundle mainBundle] pathForResource:@"ZSSRichTextEditor" ofType:@"js"];
	NSString *jsString = [[NSString alloc] initWithData:[NSData dataWithContentsOfFile:source] encoding:NSUTF8StringEncoding];
	htmlString = [htmlString stringByReplacingOccurrencesOfString:@"<!--jquery-mobile-events-->" withString:jQueryMobileEvents];
	htmlString = [htmlString stringByReplacingOccurrencesOfString:@"<!--editor-->" withString:jsString];
	
	return htmlString;
}

#pragma mark - Keyboard notifications

- (void)startObservingKeyboardNotifications
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillShow:)
                                                 name:UIKeyboardWillShowNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(keyboardWillHide:)
                                                 name:UIKeyboardWillHideNotification
                                               object:nil];
}

- (void)stopObservingKeyboardNotifications
{
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
}

#pragma mark - Keyboard status

- (void)keyboardWillShow:(NSNotification *)notification
{
    NSDictionary *info = notification.userInfo;
    CGRect keyboardEnd = [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue];
    
    CGRect localizedKeyboardEnd = [self convertRect:keyboardEnd fromView:nil];
    CGPoint keyboardOrigin = localizedKeyboardEnd.origin;
    
    if (keyboardOrigin.y > 0) {
        
        CGFloat vOffset = self.frame.size.height - keyboardOrigin.y;
        
        UIEdgeInsets insets = UIEdgeInsetsMake(0.0f, 0.0f, vOffset, 0.0f);
        
        self.sourceView.contentInset = insets;
        self.sourceView.scrollIndicatorInsets = insets;
        
        [self refreshVisibleViewportAndContentSize];
    }
}

- (void)keyboardWillHide:(NSNotification *)notification
{
    // WORKAROUND: sometimes the input accessory view is not taken into account and a
    // keyboardWillHide: call is triggered instead.  Since there's no way for the source view now
    // to have focus, we'll just make sure the inputAccessoryView is taken into account when
    // hiding the keyboard.
    //
    CGFloat vOffset = self.sourceView.inputAccessoryView.frame.size.height;
    UIEdgeInsets insets = UIEdgeInsetsMake(0.0f, 0.0f, vOffset, 0.0f);
    
    self.sourceView.contentInset = insets;
    self.sourceView.scrollIndicatorInsets = insets;
    
    [self refreshVisibleViewportAndContentSize];
}

- (void)refreshVisibleViewportAndContentSize
{
    [self.webView stringByEvaluatingJavaScriptFromString:@"ZSSEditor.refreshVisibleViewportSize();"];
    
    // DRM: enable this to debug
    //[self.webView stringByEvaluatingJavaScriptFromString:@"ZSSEditor.logMainElementSizes();"];
    
    NSString* newHeightString = [self.webView stringByEvaluatingJavaScriptFromString:@"$(document.body).height();"];
    NSInteger newHeight = [newHeightString integerValue];
    
    self.webView.scrollView.contentSize = CGSizeMake(self.frame.size.width, newHeight);
}

#pragma mark - UIWebViewDelegate

-            (BOOL)webView:(UIWebView *)webView
shouldStartLoadWithRequest:(NSURLRequest *)request
			navigationType:(UIWebViewNavigationType)navigationType
{
	NSURL *url = [request URL];
	
	BOOL shouldLoad = NO;
	
	if (navigationType != UIWebViewNavigationTypeLinkClicked) {
		BOOL handled = [self handleWebViewCallbackURL:url];
		shouldLoad = !handled;
	}

	return shouldLoad;
}

- (void)webViewDidFinishLoad:(UIWebView *)webView
{
	if ([self.delegate respondsToSelector:@selector(editorViewDidFinishLoading:)]) {
		[self.delegate editorViewDidFinishLoading:self];
	}
}

#pragma mark - UIScrollView delegate

- (void)scrollViewDidScroll:(UIScrollView *)scrollView
{
    // NOTE AUTHOR: Diego Rey Mendez
    //
    // PROBLEM: setting self.webView.scrollView.contentSize is mostly unreliable.  We tried setting
    // it when the body is resized but it wasn't working properly.  Sometimes it just failed to set
    // the proper viewport height.
    //
    // WORKAROUND: by calling this method here we make sure that the viewport size is always right
    // when editing text.
    //
    [self refreshVisibleViewportAndContentSize];
}

#pragma mark - Handling callbacks

/**
 *	@brief		Handles UIWebView callbacks.
 *
 *	@param		url		The url for the callback.  Cannot be nil.
 *
 *	@returns	YES if the callback was handled, NO otherwise.
 */
- (BOOL)handleWebViewCallbackURL:(NSURL*)url
{
	NSParameterAssert([url isKindOfClass:[NSURL class]]);

	BOOL handled = NO;

	NSString *scheme = [url scheme];
	
	NSLog(@"WebEditor callback received: %@", url);
	
    if (scheme) {
        if ([self isFocusInScheme:scheme]) {
            [self handleFocusInCallback:url];
            handled = YES;
        } else if ([self isFocusOutScheme:scheme]) {
            [self handleFocusOutCallback:url];
            handled = YES;
        } else if ([self isInputCallbackScheme:scheme]) {
            [self handleInputCallback:url];
            handled = YES;
        } else if ([self isLinkTappedScheme:scheme]) {
            [self handleLinkTappedCallback:url];
            handled = YES;
        } else if ([self isLogCallbackScheme:scheme]){
            [self handleLogCallbackScheme:url];
            handled = YES;
        } else if ([self isNewFieldCallbackScheme:scheme]) {
            [self handleNewFieldCallback:url];
            handled = YES;
        } else if ([self isSelectionStyleScheme:scheme]) {
            [self handleSelectionStyleCallback:url];
            handled = YES;
        } else if ([self isDOMLoadedScheme:scheme]) {
            [self handleDOMLoadedCallback:url];
            handled = YES;
        }
    }
	
	return handled;
}

/**
 *	@brief		Handles a DOM loaded callback.
 *
 *	@param		url		The url with all the callback information.
 */
- (void)handleDOMLoadedCallback:(NSURL*)url
{
    NSParameterAssert([url isKindOfClass:[NSURL class]]);
    
    self.editorInteractionQueue = nil;
    
    [self.titleField handleDOMLoaded];
    [self.contentField handleDOMLoaded];
    
    if ([self.delegate respondsToSelector:@selector(editorViewDidFinishLoadingDOM:)]) {
        [self.delegate editorViewDidFinishLoadingDOM:self];
    }
}

- (void)handleFocusInCallback:(NSURL*)url
{
    NSParameterAssert([url isKindOfClass:[NSURL class]]);
    
    static NSString* const kFieldIdParameterName = @"id";
    
    __weak typeof(self) weakSelf = self;
    
    [self parseParametersFromCallbackURL:url
         andExecuteBlockForEachParameter:^(NSString *parameterName, NSString *parameterValue)
     {
         if ([parameterName isEqualToString:kFieldIdParameterName]) {
             __strong typeof(weakSelf) strongSelf = weakSelf;
             
             if ([parameterValue isEqualToString:kWPEditorViewFieldTitleId]) {
                 strongSelf.focusedField = strongSelf.titleField;
             } else if ([parameterValue isEqualToString:kWPEditorViewFieldContentId]) {
                 strongSelf.focusedField = strongSelf.contentField;
             }
             
             strongSelf.webView.customInputAccessoryView = strongSelf.focusedField.inputAccessoryView;
         }
     } onComplete:^{
         [self callDelegateFieldFocused:weakSelf.focusedField];
     }];
}

/**
 *	@brief		Handles a focus out callback.
 *
 *	@param		url		The url with all the callback information.
 */
- (void)handleFocusOutCallback:(NSURL*)url
{
    NSParameterAssert([url isKindOfClass:[NSURL class]]);
    
    self.focusedField = nil;
    [self callDelegateFieldFocused:self.focusedField];
}

/**
 *	@brief		Handles a key pressed callback.
 *
 *	@param		url		The url with all the callback information.
 */
- (void)handleInputCallback:(NSURL*)url
{
    NSParameterAssert([url isKindOfClass:[NSURL class]]);
    
    [self refreshVisibleViewportAndContentSize];
    
    static NSString* const kFieldIdParameterName = @"id";
    
    __weak typeof(self) weakSelf = self;
    
    [self parseParametersFromCallbackURL:url
         andExecuteBlockForEachParameter:^(NSString *parameterName, NSString *parameterValue)
     {
         if ([parameterName isEqualToString:kFieldIdParameterName]) {
             __strong typeof(weakSelf) strongSelf = weakSelf;
             
             if ([parameterValue isEqualToString:kWPEditorViewFieldTitleId]) {
                 [strongSelf callDelegateEditorTitleDidChange];
             } else if ([parameterValue isEqualToString:kWPEditorViewFieldContentId]) {
                 [strongSelf callDelegateEditorTextDidChange];
             }
             
             strongSelf.webView.customInputAccessoryView = strongSelf.focusedField.inputAccessoryView;
         }
     } onComplete:nil];
}

/**
 *	@brief		Handles a link tapped callback.
 *
 *	@param		url		The url with all the callback information.
 */
- (void)handleLinkTappedCallback:(NSURL*)url
{
	NSParameterAssert([url isKindOfClass:[NSURL class]]);
	
	static NSString* const kTappedUrlParameterName = @"url";
	static NSString* const kTappedUrlTitleParameterName = @"title";
	
	__block NSURL* tappedUrl = nil;
	__block NSString* tappedUrlTitle = nil;
	
	[self parseParametersFromCallbackURL:url
		 andExecuteBlockForEachParameter:^(NSString *parameterName, NSString *parameterValue)
	{
		if ([parameterName isEqualToString:kTappedUrlParameterName]) {
			tappedUrl = [NSURL URLWithString:[self stringByDecodingURLFormat:parameterValue]];
		} else if ([parameterName isEqualToString:kTappedUrlTitleParameterName]) {
			tappedUrlTitle = [self stringByDecodingURLFormat:parameterValue];
		}
	} onComplete:^{		
		if ([self.delegate respondsToSelector:@selector(editorView:linkTapped:title:)]) {
			[self.delegate editorView:self linkTapped:tappedUrl title:tappedUrlTitle];
		}
	}];
}

/**
 *	@brief		Handles a log callback.
 *
 *	@param		url		The url with all the callback information.
 */
- (void)handleLogCallbackScheme:(NSURL*)url
{
    NSParameterAssert([url isKindOfClass:[NSURL class]]);
    
    static NSString* const kMessageParameterName = @"msg";
    
    [self parseParametersFromCallbackURL:url
         andExecuteBlockForEachParameter:^(NSString *parameterName, NSString *parameterValue)
     {
         if ([parameterName isEqualToString:kMessageParameterName]) {
             NSLog(@"WebEditor log:%@", [self stringByDecodingURLFormat:parameterValue]);
         }
     } onComplete:nil];
}

/**
 *	@brief		Handles a new field callback.
 *
 *	@param		url		The url with all the callback information.
 */
- (void)handleNewFieldCallback:(NSURL*)url
{
    NSParameterAssert([url isKindOfClass:[NSURL class]]);
    
    static NSString* const kFieldIdParameterName = @"id";
    
    __block NSString* fieldId = nil;
    
    [self parseParametersFromCallbackURL:url
         andExecuteBlockForEachParameter:^(NSString *parameterName, NSString *parameterValue)
     {
         if ([parameterName isEqualToString:kFieldIdParameterName]) {
             NSAssert([parameterValue isKindOfClass:[NSString class]],
                      @"We're expecting a non-nil NSString object here.");
             
             fieldId = parameterValue;
         }
     } onComplete:^{
         
         WPEditorField* newField = [self createFieldWithId:fieldId];
         
         [self callDelegateFieldCreated:newField];
     }];
}

- (void)handleSelectionStyleCallback:(NSURL*)url
{
    NSParameterAssert([url isKindOfClass:[NSURL class]]);
    
    NSString* styles = [[url resourceSpecifier] stringByReplacingOccurrencesOfString:@"//" withString:@""];
    
    [self processStyles:styles];
}

#pragma mark - Handling callbacks: identifying schemes

- (BOOL)isDOMLoadedScheme:(NSString*)scheme
{
	static NSString* const kCallbackScheme = @"callback-dom-loaded";
	
	return [scheme isEqualToString:kCallbackScheme];
}

- (BOOL)isFocusInScheme:(NSString*)scheme
{
	static NSString* const kCallbackScheme = @"callback-focus-in";
	
	return [scheme isEqualToString:kCallbackScheme];
}

- (BOOL)isFocusOutScheme:(NSString*)scheme
{
	static NSString* const kCallbackScheme = @"callback-focus-out";
	
	return [scheme isEqualToString:kCallbackScheme];
}

- (BOOL)isLinkTappedScheme:(NSString*)scheme
{
    NSAssert([scheme isKindOfClass:[NSString class]],
             @"We're expecting a non-nil string object here.");
    
	static NSString* const kCallbackScheme = @"callback-link-tap";
	
	return [scheme isEqualToString:kCallbackScheme];
}

- (BOOL)isLogCallbackScheme:(NSString*)scheme
{
    NSAssert([scheme isKindOfClass:[NSString class]],
             @"We're expecting a non-nil string object here.");
    
    static NSString* const kCallbackScheme = @"callback-log";
    
    return [scheme isEqualToString:kCallbackScheme];
}

- (BOOL)isNewFieldCallbackScheme:(NSString*)scheme
{
    NSAssert([scheme isKindOfClass:[NSString class]],
             @"We're expecting a non-nil string object here.");
    
    static NSString* const kCallbackScheme = @"callback-new-field";
    
    return [scheme isEqualToString:kCallbackScheme];
}

- (BOOL)isSelectionStyleScheme:(NSString*)scheme
{
	static NSString* const kCallbackScheme = @"callback-selection-style";

	return [scheme isEqualToString:kCallbackScheme];
}

- (BOOL)isInputCallbackScheme:(NSString*)scheme
{
	static NSString* const kCallbackScheme = @"callback-input";
	
	return [scheme isEqualToString:kCallbackScheme];
}

- (void)processStyles:(NSString *)styles
{
    NSArray *styleStrings = [styles componentsSeparatedByString:kDefaultCallbackParameterSeparator];
    NSMutableArray *itemsModified = [[NSMutableArray alloc] init];
	
	self.selectedImageURL = nil;
	self.selectedImageAlt = nil;
	self.selectedLinkURL = nil;
	self.selectedLinkTitle = nil;
	
    for (NSString *styleString in styleStrings) {
        NSString *updatedItem = styleString;
        if ([styleString hasPrefix:@"link:"]) {
            updatedItem = @"link";
            self.selectedLinkURL = [self stringByDecodingURLFormat:[styleString stringByReplacingOccurrencesOfString:@"link:" withString:@""]];
        } else if ([styleString hasPrefix:@"link-title:"]) {
            self.selectedLinkTitle = [self stringByDecodingURLFormat:[styleString stringByReplacingOccurrencesOfString:@"link-title:" withString:@""]];
        } else if ([styleString hasPrefix:@"image:"]) {
            updatedItem = @"image";
            self.selectedImageURL = [styleString stringByReplacingOccurrencesOfString:@"image:" withString:@""];
        } else if ([styleString hasPrefix:@"image-alt:"]) {
            self.selectedImageAlt = [self stringByDecodingURLFormat:[styleString stringByReplacingOccurrencesOfString:@"image-alt:" withString:@""]];
        }
        [itemsModified addObject:updatedItem];
    }
	
    styleStrings = [NSArray arrayWithArray:itemsModified];
    
	if ([self.delegate respondsToSelector:@selector(editorView:stylesForCurrentSelection:)])
	{
		[self.delegate editorView:self stylesForCurrentSelection:styleStrings];
	}
}

#pragma mark - Callback parsing

/**
 *	@brief		Extract the components that make up a parameter.
 *	@details	Should always be two (for example: 'value=65' would return @['value', '65']).
 *
 *	@param		parameter	The string parameter to parse.  Cannot be nil.
 *
 *	@returns	An array containing each component.
 */
- (NSArray*)componentsFromParameter:(NSString*)parameter
{
	NSParameterAssert([parameter isKindOfClass:[NSString class]]);
    
    NSRange range = [parameter rangeOfString:kDefaultCallbackParameterComponentSeparator];
    
    NSString* parameterName = [parameter substringToIndex:range.location];
    NSString* parameterValue = [parameter substringFromIndex:range.location + range.length];
    
    NSArray* components = @[parameterName, parameterValue];
	NSAssert([components count] == 2,
			 @"We're expecting exactly two components here.");
	
	return components;
}

/**
 *	@brief		This is a very helpful method for parsing through a callback's parameters and
 *				performing custom processing when each parameter and value is identified.
 *
 *	@param		url					The callback URL to process.  Cannot be nil.
 *	@param		block				Will be executed one time for each parameter identified by the
 *									parser.  Cannot be nil.
 *	@param		onCompleteBlock		The block to execute when the parsing finishes.  Can be nil.
 */
- (void)parseParametersFromCallbackURL:(NSURL*)url
	   andExecuteBlockForEachParameter:(WPEditorViewCallbackParameterProcessingBlock)block
							onComplete:(WPEditorViewNoParamsCompletionBlock)onCompleteBlock
{
	NSParameterAssert([url isKindOfClass:[NSURL class]]);
	NSParameterAssert(block);
	
	NSArray* parameters = [self parametersFromCallbackURL:url];
	
	for (NSString* parameter in parameters) {
		NSAssert([parameter isKindOfClass:[NSString class]],
				 @"We're expecting to have a non-nil NSString object here.");
		
        NSArray* components = [self componentsFromParameter:parameter];
        NSAssert([components count] == 2,
                 @"We're expecting exactly two components here.");
		
		block([components objectAtIndex:0], [components objectAtIndex:1]);
	}
	
	if (onCompleteBlock) {
		onCompleteBlock();
	}
}

/**
 *	@brief		Extract the parameters that make up a callback URL.
 *
 *	@param		url		The callback URL to parse.  Cannot be nil.
 *
 *	@returns	An array containing each parameter.
 */
- (NSArray*)parametersFromCallbackURL:(NSURL*)url
{
	NSParameterAssert([url isKindOfClass:[NSURL class]]);
	
	NSArray* parameters = [[url resourceSpecifier] componentsSeparatedByString:kDefaultCallbackParameterSeparator];
	
	return parameters;
}

#pragma mark - Fields

/**
 *  @brief      Creates a field for the specified id.
 *  @todo       At some point it would be nice to have WPEditorView be able to handle a custom list
 *              of fields, instead of expecting the HTML page to only have a title and a content
 *              field.
 *
 *  @param      fieldId     The id of the field to create.  This is the id of the html node that
 *                          our new field will wrap.  Cannot be nil.
 *
 *  @returns    The newly created field.
 */
- (WPEditorField*)createFieldWithId:(NSString*)fieldId
{
    NSAssert([fieldId isKindOfClass:[NSString class]],
             @"We're expecting a non-nil NSString object here.");
    
    WPEditorField* newField = nil;
    
    if ([fieldId isEqualToString:kWPEditorViewFieldTitleId]) {
        NSAssert(!_titleField,
                 @"We should never have to set this twice.");
        
        _titleField = [[WPEditorField alloc] initWithId:fieldId webView:self.webView];
        newField = self.titleField;
    } else if ([fieldId isEqualToString:kWPEditorViewFieldContentId]) {
        NSAssert(!_contentField,
                 @"We should never have to set this twice.");
        
        _contentField = [[WPEditorField alloc] initWithId:fieldId webView:self.webView];
        newField = self.contentField;
    }
    NSAssert([newField isKindOfClass:[WPEditorField class]],
             @"A new field should've been created here.");
    
    return newField;
}

#pragma mark - URL & HTML utilities

/**
 *  @brief      Adds slashes to the specified HTML string, to prevent injections when calling JS
 *              code.
 *
 *  @param      html        The HTML string to add slashes to.  Cannot be nil.
 *
 *  @returns    The HTML string with the added slashes.
 */
- (NSString *)addSlashes:(NSString *)html
{
    html = [html stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    html = [html stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    html = [html stringByReplacingOccurrencesOfString:@"\r"  withString:@"\\r"];
    html = [html stringByReplacingOccurrencesOfString:@"\n"  withString:@"\\n"];
    
    return html;
}

- (NSString *)stringByDecodingURLFormat:(NSString *)string
{
    NSString *result = [string stringByReplacingOccurrencesOfString:@"+" withString:@" "];
    result = [result stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];
    return result;
}

#pragma mark - Interaction

- (void)undo
{
    [self.webView stringByEvaluatingJavaScriptFromString:@"ZSSEditor.undo();"];
	
    [self callDelegateEditorTextDidChange];
}

- (void)redo
{
    [self.webView stringByEvaluatingJavaScriptFromString:@"ZSSEditor.redo();"];
	
    [self callDelegateEditorTextDidChange];
}

#pragma mark - Selection

- (void)restoreSelection
{
	[self.webView stringByEvaluatingJavaScriptFromString:@"ZSSEditor.restoreRange();"];
}

- (void)saveSelection
{
    [self.webView stringByEvaluatingJavaScriptFromString:@"ZSSEditor.backupRange();"];
}

- (NSString*)selectedText
{
	NSString* selectedText = [self.webView stringByEvaluatingJavaScriptFromString:@"ZSSEditor.getSelectedText();"];
	
	return selectedText;
}

- (void)setSelectedColor:(UIColor*)color tag:(int)tag
{
    NSString *hex = [NSString stringWithFormat:@"#%06x",HexColorFromUIColor(color)];
    NSString *trigger;
    if (tag == 1) {
        trigger = [NSString stringWithFormat:@"ZSSEditor.setTextColor(\"%@\");", hex];
    } else if (tag == 2) {
        trigger = [NSString stringWithFormat:@"ZSSEditor.setBackgroundColor(\"%@\");", hex];
    }
	
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];
	
    [self callDelegateEditorTextDidChange];
}

#pragma mark - Images

- (void)insertImage:(NSString *)url alt:(NSString *)alt
{
    NSString *trigger = [NSString stringWithFormat:@"ZSSEditor.insertImage(\"%@\", \"%@\");", url, alt];
    [self.webView stringByEvaluatingJavaScriptFromString:trigger];
}

- (void)updateImage:(NSString *)url alt:(NSString *)alt
{
    NSString *trigger = [NSString stringWithFormat:@"ZSSEditor.updateImage(\"%@\", \"%@\");", url, alt];
    [self.webView stringByEvaluatingJavaScriptFromString:trigger];
}

#pragma mark - Links

- (void)insertLink:(NSString *)url
			 title:(NSString*)title
{
	NSParameterAssert([url isKindOfClass:[NSString class]]);
	NSParameterAssert([title isKindOfClass:[NSString class]]);
	
	NSString *trigger = [NSString stringWithFormat:@"ZSSEditor.insertLink(\"%@\",\"%@\");", url, title];
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];
	
    [self callDelegateEditorTextDidChange];
}

- (BOOL)isSelectionALink
{
	return self.selectedLinkURL != nil;
}

- (void)updateLink:(NSString *)url
			 title:(NSString*)title
{
	NSParameterAssert([url isKindOfClass:[NSString class]]);
	NSParameterAssert([title isKindOfClass:[NSString class]]);
	
	NSString *trigger = [NSString stringWithFormat:@"ZSSEditor.updateLink(\"%@\",\"%@\");", url, title];
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];
	
    [self callDelegateEditorTextDidChange];
}

- (void)removeLink
{
	[self.webView stringByEvaluatingJavaScriptFromString:@"ZSSEditor.unlink();"];
}

- (void)quickLink
{
	[self.webView stringByEvaluatingJavaScriptFromString:@"ZSSEditor.quickLink();"];
}

#pragma mark - Editor: HTML interaction

// Inserts HTML at the caret position
- (void)insertHTML:(NSString *)html
{
    NSString *cleanedHTML = [self addSlashes:html];
    NSString *trigger = [NSString stringWithFormat:@"ZSSEditor.insertHTML(\"%@\");", cleanedHTML];
    [self.webView stringByEvaluatingJavaScriptFromString:trigger];
}

#pragma mark - Editing

- (void)endEditing;
{
	[self.webView endEditing:YES];
	[self.sourceView endEditing:YES];
}

#pragma mark - Editor mode

- (BOOL)isInVisualMode
{
	return !self.webView.hidden;
}

- (void)showHTMLSource
{
	self.sourceView.text = [self.contentField html];
	self.sourceView.hidden = NO;
	self.webView.hidden = YES;
    
    [self.sourceView becomeFirstResponder];
    UITextPosition* position = [self.sourceView positionFromPosition:[self.sourceView beginningOfDocument]
                                                              offset:0];
    
    [self.sourceView setSelectedTextRange:[self.sourceView textRangeFromPosition:position toPosition:position]];
}

- (void)showVisualEditor
{
	[self.contentField setHtml:self.sourceView.text];
	self.sourceView.hidden = YES;
	self.webView.hidden = NO;
    
    [self.titleField focus];
}

#pragma mark - Editing lock

- (void)disableEditing
{
    [self.titleField disableEditing];
    [self.contentField disableEditing];
}

- (void)enableEditing
{
    [self.titleField enableEditing];
    [self.contentField enableEditing];
}

#pragma mark - Styles

- (void)alignLeft
{
    NSString *trigger = @"ZSSEditor.setJustifyLeft();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];
    
    [self callDelegateEditorTextDidChange];
}

- (void)alignCenter
{
    NSString *trigger = @"ZSSEditor.setJustifyCenter();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)alignRight
{
    NSString *trigger = @"ZSSEditor.setJustifyRight();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)alignFull
{
    NSString *trigger = @"ZSSEditor.setJustifyFull();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setBold
{
    NSString *trigger = @"ZSSEditor.setBold();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setBlockQuote
{
    NSString *trigger = @"ZSSEditor.setBlockquote();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setItalic
{
    NSString *trigger = @"ZSSEditor.setItalic();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setSubscript
{
    NSString *trigger = @"ZSSEditor.setSubscript();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setUnderline
{
    NSString *trigger = @"ZSSEditor.setUnderline();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setSuperscript
{
    NSString *trigger = @"ZSSEditor.setSuperscript();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setStrikethrough
{
    NSString *trigger = @"ZSSEditor.setStrikeThrough();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setUnorderedList
{
    NSString *trigger = @"ZSSEditor.setUnorderedList();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setOrderedList
{
    NSString *trigger = @"ZSSEditor.setOrderedList();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setHR
{
    NSString *trigger = @"ZSSEditor.setHorizontalRule();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setIndent
{
    NSString *trigger = @"ZSSEditor.setIndent();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)setOutdent
{
    NSString *trigger = @"ZSSEditor.setOutdent();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)heading1
{
    NSString *trigger = @"ZSSEditor.setHeading('h1');";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)heading2
{
    NSString *trigger = @"ZSSEditor.setHeading('h2');";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)heading3
{
    NSString *trigger = @"ZSSEditor.setHeading('h3');";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)heading4
{
    NSString *trigger = @"ZSSEditor.setHeading('h4');";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)heading5
{
    NSString *trigger = @"ZSSEditor.setHeading('h5');";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

- (void)heading6
{
    NSString *trigger = @"ZSSEditor.setHeading('h6');";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}


- (void)removeFormat
{
    NSString *trigger = @"ZSSEditor.removeFormating();";
	[self.webView stringByEvaluatingJavaScriptFromString:trigger];

    [self callDelegateEditorTextDidChange];
}

#pragma mark - Delegate calls

/**
 *  @brief      Call's the delegate editorTextDidChange: method.
 */
- (void)callDelegateEditorTextDidChange
{
    if ([self.delegate respondsToSelector: @selector(editorTextDidChange:)]) {
        [self.delegate editorTextDidChange:self];
    }
}

/**
 *  @brief      Call's the delegate editorTitleDidChange: method.
 */
- (void)callDelegateEditorTitleDidChange
{
    if ([self.delegate respondsToSelector: @selector(editorTitleDidChange:)]) {
        [self.delegate editorTitleDidChange:self];
    }
}

/**
 *  @brief      Call's the delegate editorView:fieldCreated: method.
 */
- (void)callDelegateFieldCreated:(WPEditorField*)field
{
    NSParameterAssert([field isKindOfClass:[WPEditorField class]]);
    
    if ([self.delegate respondsToSelector:@selector(editorView:fieldCreated:)]) {
        [self.delegate editorView:self fieldCreated:field];
    }
}

/**
 *  @brief      Call's the delegate editorView:fieldFocused: method.
 */
- (void)callDelegateFieldFocused:(WPEditorField*)field
{
    if ([self.delegate respondsToSelector:@selector(editorView:fieldFocused:)]) {
        [self.delegate editorView:self fieldFocused:field];
    }
}

@end