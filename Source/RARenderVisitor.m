//
//  RARenderVisitor.m
//  RASceneGraphMac
//
//  Created by Ross Anderson on 2/18/12.
//  Copyright (c) 2012 Ross Anderson. All rights reserved.
//

#import "RARenderVisitor.h"

#import <GLKit/GLKVector3.h>
#import <GLKit/GLKMatrix4.h>
#import <GLKit/GLKMathUtils.h>

#import "RABoundingSphere.h"
#import "RAShaderProgram.h"

// Uniform index.
enum
{
    UNIFORM_MODELVIEWPROJECTION_MATRIX,
//    UNIFORM_NORMAL_MATRIX,
    UNIFORM_TEXTURE0,
    UNIFORM_LIGHT_DIRECTION,
    UNIFORM_LIGHT_AMBIENT_COLOR,
    UNIFORM_LIGHT_DIFFUSE_COLOR,
    NUM_UNIFORMS
};

// Attribute index.
/*enum
{
    ATTRIB_VERTEX,
    ATTRIB_NORMAL,
    NUM_ATTRIBUTES
};*/


#pragma mark -

@interface RenderData : NSObject
@property (retain, atomic) RAGeometry * geometry;
@property (assign, atomic) GLKMatrix4 modelviewMatrix;
@property (assign, atomic) float distanceFromCamera;
@end

@implementation RenderData
@synthesize geometry = _geometry;
@synthesize modelviewMatrix = _modelviewMatrix;
@synthesize distanceFromCamera = _distanceFromCamera;
@end

#pragma mark -

@implementation RARenderVisitor {
    NSMutableArray *    renderQueue;
    RAShaderProgram *   shader;
}

@synthesize camera;
@synthesize lightPosition = _lightPosition, lightAmbientColor = _lightAmbientColor, lightDiffuseColor = _lightDiffuseColor;

- (id)init
{
    self = [super init];
    if (self) {
        renderQueue = [NSMutableArray new];
        shader = [[RAShaderProgram alloc] init];
        
        self.camera = [RACamera new];
        self.camera.modelViewMatrix = GLKMatrix4Identity;
        
        self.lightPosition = GLKVector3Make(1.0, 1.0, 1.0);
        self.lightAmbientColor = GLKVector4Make(0.1, 0.1, 0.1, 1.0);
        self.lightDiffuseColor = GLKVector4Make(0.9, 0.9, 0.9, 1.0);
    }
    return self;
}

- (void)clear
{
    [renderQueue removeAllObjects];
}

- (void)sortBackToFront
{
    [renderQueue sortUsingComparator:(NSComparator)^(RenderData* obj1, RenderData* obj2) {
        return obj1.distanceFromCamera > obj2.distanceFromCamera;
    }];
}

- (void)setupGL
{
    if ( [shader loadShader:@"Shader"] ) {
        [shader bindAttribute:@"position" toIdentifier:GLKVertexAttribPosition];
        [shader bindAttribute:@"normal" toIdentifier:GLKVertexAttribNormal];
        [shader bindAttribute:@"textureCoordinate" toIdentifier:GLKVertexAttribTexCoord0];

        [shader link];
        
        [shader bindUniform:@"modelViewProjectionMatrix" toIdentifier:UNIFORM_MODELVIEWPROJECTION_MATRIX];
        [shader bindUniform:@"lightDirection" toIdentifier:UNIFORM_LIGHT_DIRECTION];
        [shader bindUniform:@"lightAmbientColor" toIdentifier:UNIFORM_LIGHT_AMBIENT_COLOR];
        [shader bindUniform:@"lightDiffuseColor" toIdentifier:UNIFORM_LIGHT_DIFFUSE_COLOR];
        [shader bindUniform:@"texture0" toIdentifier:UNIFORM_TEXTURE0];
    }
}

- (void)tearDownGL
{
    [shader tearDownGL];
}

- (void)render
{
    //NSLog(@"Rendering %d objects", renderQueue.count);
    
    [self sortBackToFront];
    
    if ( ! [shader isReady] ) [self setupGL];
    [shader use];
    
    // set light source
    [shader setUniform:UNIFORM_LIGHT_DIRECTION toVector3:GLKVector3Normalize(self.lightPosition)];
    [shader setUniform:UNIFORM_LIGHT_AMBIENT_COLOR toVector4:self.lightAmbientColor];
    [shader setUniform:UNIFORM_LIGHT_DIFFUSE_COLOR toVector4:self.lightDiffuseColor];
    
    [shader setUniform:UNIFORM_TEXTURE0 toInt:0];

    [renderQueue enumerateObjectsUsingBlock:^(RenderData * child, NSUInteger idx, BOOL *stop) {
        //GLKMatrix3 normalMatrix = GLKMatrix3InvertAndTranspose(GLKMatrix4GetMatrix3(child.modelviewMatrix), NULL);
        GLKMatrix4 modelViewProjectionMatrix = GLKMatrix4Multiply(self.camera.projectionMatrix, child.modelviewMatrix);
        
        [shader setUniform:UNIFORM_MODELVIEWPROJECTION_MATRIX toMatrix4:modelViewProjectionMatrix];
        //[shader setUniform:UNIFORM_NORMAL_MATRIX toMatrix4:normalMatrix];
        
        [child.geometry renderGL];
    }];
}

/*- (void)applyNode:(RANode *)node
{
    GLKMatrix4 modelProj = GLKMatrix4Multiply( [self currentTransform], self.projection );
    
    // project node center into viewport
    GLKVector3 pc = GLKMatrix4MultiplyVector3( modelProj, node.bound.center );
    
    //NSLog(@"Node %@, transform = %@", node, NSStringFromGLKMatrix4([self currentTransform]));
    
    // reject subgraphs behind camera
    //if ( pc.z > 0.0f ) return;
    
    [node traverse: self];
}*/

- (void)applyGeometry:(RAGeometry *)node
{
    GLKMatrix4 modelViewMatrix = GLKMatrix4Multiply( self.camera.modelViewMatrix, [self currentTransform] );
    GLKMatrix4 modelViewProjectionMatrix = GLKMatrix4Multiply( self.camera.projectionMatrix, modelViewMatrix );
    
    // project node center into viewport
    GLKVector3 pc = GLKMatrix4MultiplyAndProjectVector3( modelViewProjectionMatrix, node.bound.center );
    
    // !!! if it's outside the viewport, chuck it
        
    // insert into render queue
    RenderData * data = [RenderData new];
    data.geometry = node;
    data.modelviewMatrix = modelViewMatrix;
    data.distanceFromCamera = -pc.z;
    [renderQueue addObject: data];
}

- (void)applyPageNode:(RAPageNode *)node
{
    GLKMatrix4 modelViewMatrix = GLKMatrix4Multiply( self.camera.modelViewMatrix, [self currentTransform] );
    GLKMatrix4 modelViewProjectionMatrix = GLKMatrix4Multiply( self.camera.projectionMatrix, modelViewMatrix );

    [self traversePage:node.page withModelViewProjectionMatrix:modelViewProjectionMatrix];
}

- (BOOL)traversePage:(RAPage *)page withModelViewProjectionMatrix:(GLKMatrix4)matrix {
    if ( page == nil ) return NO;
    
    // don't bother traversing if we are offscreen
    if ( ! [page isOnscreenWithCamera:self.camera] ) {
        return YES;
    }

    // is the page facing away from the camera?
    if ( page.tile.z > 2 && [page calculateTiltWithCamera:self.camera] < 0.0f ) return YES;
    
    float texelError = [page calculateScreenSpaceErrorWithCamera:self.camera];
    
    // should we choose to display this page?
    if ( texelError < 6.0f && page.isReady ) {
        [self applyGeometry: page.geometry];
        return YES;
    }
    
    BOOL success = YES;
    
    // !!! this doesn't work well because it can't skip to grandchildren: each level must be loaded consecutively
    success = ( page.child1.isReady && page.child2.isReady && page.child3.isReady && page.child4.isReady );
    
    // traverse children
    if ( success ) {
        [self traversePage:page.child1 withModelViewProjectionMatrix:matrix];
        [self traversePage:page.child2 withModelViewProjectionMatrix:matrix];
        [self traversePage:page.child3 withModelViewProjectionMatrix:matrix];
        [self traversePage:page.child4 withModelViewProjectionMatrix:matrix];
    } else if ( page.isReady ) {
        // don't bother traversing if we are offscreen
        if ( ! [page isOnscreenWithCamera:self.camera] ) return YES;
        
        [self applyGeometry: page.geometry];
        return YES;
    }
    
    return success;
}


@end
