/*
 * kernels.cu
 *
 *  Created on: Jun 20, 2017
 *      Author: kbmod-usr
 * funcs that use RESULTS_PER_PIXEL are:
 * searchImages, searchFilterImages. These functions are called in
 * deviceSearch and deviceSearchFilter
 */

#ifndef KERNELS_CU_
#define KERNELS_CU_
#define GPU_LC_FILTER 1
#define MAX_NUM_IMAGES 140

#include "common.h"
//#include "PointSpreadFunc.h"
#include <helper_cuda.h>
#include <stdio.h>
#include <float.h>

namespace kbmod {


/*
 * Device kernel that convolves the provided image with the psf
 */
__global__ void convolvePSF(int width, int height,
    float *sourceImage, float *resultImage, float *psf,
    int psfRad, int psfDim, float psfSum, float maskFlag)
{
    // Find bounds of convolution area
    const int x = blockIdx.x*CONV_THREAD_DIM+threadIdx.x;
    const int y = blockIdx.y*CONV_THREAD_DIM+threadIdx.y;
    if (x < 0 || x > width-1 || y < 0 || y > height-1) return;
    const int minX = max(x-psfRad, 0);
    const int minY = max(y-psfRad, 0);
    const int maxX = min(x+psfRad, width-1);
    const int maxY = min(y+psfRad, height-1);

    // Read kernel
    float sum = 0.0;
    float psfPortion = 0.0;
    float center = sourceImage[y*width+x];
    if (center != NO_DATA) {
        for (int j=minY; j<=maxY; j++)
        {
            // #pragma unroll
            for (int i=minX; i<=maxX; i++)
            {
                float currentPixel = sourceImage[j*width+i];
                if (currentPixel != NO_DATA) {
                    float currentPSF = psf[(j-minY)*psfDim+i-minX];
                    psfPortion += currentPSF;
                    sum += currentPixel * currentPSF;
                }
            }
        }

        resultImage[y*width+x] = (sum*psfSum)/psfPortion;
    } else {
        // Leave masked pixel alone (these could be replaced here with zero)
        resultImage[y*width+x] = NO_DATA; // 0.0
    }
}

extern "C" void deviceConvolve(float *sourceImg, float *resultImg,
    int width, int height, float *psfKernel,
    int psfSize, int psfDim, int psfRadius, float psfSum)
{
    // Pointers to device memory //
    float *deviceKernel;
    float *deviceSourceImg;
    float *deviceResultImg;

    long pixelsPerImage = width*height;
    dim3 blocks(width/CONV_THREAD_DIM+1,height/CONV_THREAD_DIM+1);
    dim3 threads(CONV_THREAD_DIM,CONV_THREAD_DIM);

    // Allocate Device memory
    checkCudaErrors(cudaMalloc((void **)&deviceKernel, sizeof(float)*psfSize));
    checkCudaErrors(cudaMalloc((void **)&deviceSourceImg, sizeof(float)*pixelsPerImage));
    checkCudaErrors(cudaMalloc((void **)&deviceResultImg, sizeof(float)*pixelsPerImage));

    checkCudaErrors(cudaMemcpy(deviceKernel, psfKernel,
        sizeof(float)*psfSize, cudaMemcpyHostToDevice));

    checkCudaErrors(cudaMemcpy(deviceSourceImg, sourceImg,
        sizeof(float)*pixelsPerImage, cudaMemcpyHostToDevice));

    convolvePSF<<<blocks, threads>>> (width, height, deviceSourceImg,
        deviceResultImg, deviceKernel, psfRadius, psfDim, psfSum, NO_DATA);

    checkCudaErrors(cudaMemcpy(resultImg, deviceResultImg,
        sizeof(float)*pixelsPerImage, cudaMemcpyDeviceToHost));

    checkCudaErrors(cudaFree(deviceKernel));
    checkCudaErrors(cudaFree(deviceSourceImg));
    checkCudaErrors(cudaFree(deviceResultImg));
}

// Reads a single pixel from an image buffer
__device__ float readPixel(float* img, int x, int y, int width, int height)
{
    return (x<width && y<height) ? img[y*width+x] : NO_DATA;
}

__device__ float maxMasked(float pixel, float previousMax)
{
    return pixel == NO_DATA ? previousMax : max(pixel, previousMax);
}

__device__ float minMasked(float pixel, float previousMin)
{
    return pixel == NO_DATA ? previousMin : min(pixel, previousMin);
}

/*
 * Reduces the resolution of an image to 1/4 using max pooling
 */
__global__ void pool(int sourceWidth, int sourceHeight, float *source,
    int destWidth, int destHeight, float *dest, short mode)
{
    const int x = blockIdx.x*POOL_THREAD_DIM+threadIdx.x;
    const int y = blockIdx.y*POOL_THREAD_DIM+threadIdx.y;
    if (x>=destWidth || y>=destHeight) return;
    float mp;
    float pixel;
    if (mode == POOL_MAX) {
        mp = -FLT_MAX;
        pixel = readPixel(source, 2*x,   2*y,   sourceWidth, sourceHeight);
        mp = maxMasked(pixel, mp);
        pixel = readPixel(source, 2*x+1, 2*y,   sourceWidth, sourceHeight);
        mp = maxMasked(pixel, mp);
        pixel = readPixel(source, 2*x,   2*y+1, sourceWidth, sourceHeight);
        mp = maxMasked(pixel, mp);
        pixel = readPixel(source, 2*x+1, 2*y+1, sourceWidth, sourceHeight);
        mp = maxMasked(pixel, mp);
        if (mp == FLT_MIN) mp = NO_DATA;
    } else {
        mp = FLT_MAX;
        pixel = readPixel(source, 2*x,   2*y,   sourceWidth, sourceHeight);
        mp = minMasked(pixel, mp);
        pixel = readPixel(source, 2*x+1, 2*y,   sourceWidth, sourceHeight);
        mp = minMasked(pixel, mp);
        pixel = readPixel(source, 2*x,   2*y+1, sourceWidth, sourceHeight);
        mp = minMasked(pixel, mp);
        pixel = readPixel(source, 2*x+1, 2*y+1, sourceWidth, sourceHeight);
        mp = minMasked(pixel, mp);
        if (mp == FLT_MAX) mp = NO_DATA;
    }

    dest[y*destWidth+x] = mp;
}

extern "C" void devicePool(int sourceWidth, int sourceHeight, float *source,
    int destWidth, int destHeight, float *dest, short mode)
{
    // Pointers to device memory //
    float *deviceSourceImg;
    float *deviceResultImg;

    dim3 blocks(destWidth/POOL_THREAD_DIM+1,destHeight/POOL_THREAD_DIM+1);
    dim3 threads(POOL_THREAD_DIM,POOL_THREAD_DIM);

    int srcPixCount = sourceWidth*sourceHeight;
    int destPixCount = destWidth*destHeight;

    // Allocate Device memory
    checkCudaErrors(cudaMalloc((void **)&deviceSourceImg, sizeof(float)*srcPixCount));
    checkCudaErrors(cudaMalloc((void **)&deviceResultImg, sizeof(float)*destPixCount));

    checkCudaErrors(cudaMemcpy(deviceSourceImg, source,
        sizeof(float)*srcPixCount, cudaMemcpyHostToDevice));

    pool<<<blocks, threads>>> (sourceWidth, sourceHeight, deviceSourceImg,
            destWidth, destHeight, deviceResultImg, mode);

    checkCudaErrors(cudaMemcpy(dest, deviceResultImg,
        sizeof(float)*destPixCount, cudaMemcpyDeviceToHost));

    checkCudaErrors(cudaFree(deviceSourceImg));
    checkCudaErrors(cudaFree(deviceResultImg));
}

/*
 * Searches through images (represented as a flat array of floats) looking for most likely
 * trajectories in the given list. Outputs a results image of best trajectories. Returns a
 * fixed number of results per pixel specified by RESULTS_PER_PIXEL
 */
__global__ void searchImages(int trajectoryCount, int width, int height,
    int imageCount, int minObservations, float *psiPhiImages,
    trajectory *trajectories, trajectory *results, float *imgTimes)
{

    // Get trajectory origin
    const unsigned short x = blockIdx.x*THREAD_DIM_X+threadIdx.x;
    const unsigned short y = blockIdx.y*THREAD_DIM_Y+threadIdx.y;
    trajectory best[RESULTS_PER_PIXEL];
    for (int r=0; r<RESULTS_PER_PIXEL; ++r)
    {
        best[r].lh = -1.0;
    }

    __shared__ float sImgTimes[512];
    int idx = threadIdx.x+threadIdx.y*THREAD_DIM_X;
    if (idx<imageCount) sImgTimes[idx] = imgTimes[idx];

    // Give up on any trajectories starting outside the image
    if (x >= width || y >= height)
    {
        return;
    }

    const unsigned int pixelsPerImage = width*height;

    // For each trajectory we'd like to search
    for (int t=0; t<trajectoryCount; ++t)
    {
        trajectory currentT;
        currentT.x = x;
        currentT.y = y;
        currentT.xVel = trajectories[t].xVel;
        currentT.yVel = trajectories[t].yVel;
        currentT.obsCount = 0;

        float psiSum = 0.0;
        float phiSum = 0.0;

        // Loop over each image and sample the appropriate pixel
        for (int i=0; i<imageCount; ++i)
        {
            float cTime = sImgTimes[i];
            int currentX = x + int(currentT.xVel*cTime+0.5);
            int currentY = y + int(currentT.yVel*cTime+0.5);
            // Test if trajectory goes out of image bounds
            // Branching could be avoided here by setting a
            // black image border and clamping coordinates
            if (currentX >= width || currentY >= height
                || currentX < 0 || currentY < 0)
            {
                // Penalize trajctories that leave edge
                //psiSum += -0.1;
                continue;
            }
            unsigned int pixel = (pixelsPerImage*i +
                 currentY*width +
                 currentX);

            //float cPsi = psiPhiImages[pixel];
            //float cPhi = psiPhiImages[pixel+1];
            float2 cPsiPhi = reinterpret_cast<float2*>(psiPhiImages)[pixel];
            if (cPsiPhi.x == NO_DATA) continue;

            currentT.obsCount++;
            psiSum += cPsiPhi.x;// < NO_DATA/2 /*== NO_DATA* / ? 0.0 : cPsiPhi.x;//min(cPsi,0.3);
            phiSum += cPsiPhi.y;// < NO_DATA/2 /*== NO_DATA* / ? 0.0 : cPsiPhi.y;
            //if (psiSum <= 0.0 && i>4) break;
        }
        // Just in case a phiSum is zero
        //phiSum += phiSum*1.0005+0.001;
        currentT.lh = psiSum/sqrt(phiSum);
        currentT.flux = /*2.0*fluxPix**/ psiSum/phiSum;
        trajectory temp;
        for (int r=0; r<RESULTS_PER_PIXEL; ++r)
        {
            if ( currentT.lh > best[r].lh &&
                 currentT.obsCount >= minObservations )
            {
                temp = best[r];
                best[r] = currentT;
                currentT = temp;
            }
        }
    }
    for (int r=0; r<RESULTS_PER_PIXEL; ++r)
    {
        results[ (y*width + x)*RESULTS_PER_PIXEL + r ] = best[r];
    }
    delete[] best;
}

extern "C" void
deviceSearch(int trajCount, int imageCount, int minObservations, int psiPhiSize,
    int resultsCount, trajectory *trajectoriesToSearch, trajectory *bestTrajects,
    float *imageTimes, float *interleavedPsiPhi, int width, int height)
{
    // Allocate Device memory
    trajectory *deviceTests;
    float *deviceImgTimes;
    float *devicePsiPhi;
    trajectory *deviceSearchResults;

    checkCudaErrors(cudaMalloc((void **)&deviceTests, sizeof(trajectory)*trajCount));
    checkCudaErrors(cudaMalloc((void **)&deviceImgTimes, sizeof(float)*imageCount));
    checkCudaErrors(cudaMalloc((void **)&devicePsiPhi,
        sizeof(float)*psiPhiSize));
    checkCudaErrors(cudaMalloc((void **)&deviceSearchResults,
        sizeof(trajectory)*resultsCount));

    // Copy trajectories to search
    checkCudaErrors(cudaMemcpy(deviceTests, trajectoriesToSearch,
            sizeof(trajectory)*trajCount, cudaMemcpyHostToDevice));

    // Copy image times
    checkCudaErrors(cudaMemcpy(deviceImgTimes, imageTimes,
            sizeof(float)*imageCount, cudaMemcpyHostToDevice));

    // Copy interleaved buffer of psi and phi images
    checkCudaErrors(cudaMemcpy(devicePsiPhi, interleavedPsiPhi,
        sizeof(float)*psiPhiSize, cudaMemcpyHostToDevice));

    //dim3 blocks(width,height);
    dim3 blocks(width/THREAD_DIM_X+1,height/THREAD_DIM_Y+1);
    dim3 threads(THREAD_DIM_X,THREAD_DIM_Y);


    // Launch Search
    searchImages<<<blocks, threads>>> (trajCount, width,
        height, imageCount, minObservations, devicePsiPhi,
        deviceTests, deviceSearchResults, deviceImgTimes);

    // Read back results
    checkCudaErrors(cudaMemcpy(bestTrajects, deviceSearchResults,
                sizeof(trajectory)*resultsCount, cudaMemcpyDeviceToHost));

    checkCudaErrors(cudaFree(deviceTests));
    checkCudaErrors(cudaFree(deviceImgTimes));
    checkCudaErrors(cudaFree(deviceSearchResults));
    checkCudaErrors(cudaFree(devicePsiPhi));
}

/*
 * Searches through images (represented as a flat array of floats) looking for most likely
 * trajectories in the given list. Outputs a results image of best trajectories. Returns a
 * fixed number of results per pixel specified by RESULTS_PER_PIXEL
 * filters results using a sigmaG-based filter and a central-moment filter.
 */
__global__ void searchFilterImages(int trajectoryCount, int width, int height,
        int imageCount, int minObservations, float *psiPhiImages,
        trajectory *trajectories, trajectory *results, float *imgTimes,
        float sGL0, float sGL1, float sigmaGCoeff, float minLH)
{

    // Get trajectory origin
    const unsigned short x = blockIdx.x*THREAD_DIM_X+threadIdx.x;
    const unsigned short y = blockIdx.y*THREAD_DIM_Y+threadIdx.y;
    float lcArray[MAX_NUM_IMAGES];
    float psiArray[MAX_NUM_IMAGES];
    float phiArray[MAX_NUM_IMAGES];
    int idxArray[MAX_NUM_IMAGES];
    float tmpSortValue;
    int tmpSortIdx;
    trajectory best[RESULTS_PER_PIXEL];
    for (int r=0; r<RESULTS_PER_PIXEL; ++r)
    {
        best[r].lh = -1.0;
    }

    __shared__ float sImgTimes[512];
    int idx = threadIdx.x+threadIdx.y*THREAD_DIM_X;
    if (idx<imageCount) sImgTimes[idx] = imgTimes[idx];

    // Give up on any trajectories starting outside the image
    if (x >= width || y >= height)
    {
        return;
    }

    const unsigned int pixelsPerImage = width*height;

    // For each trajectory we'd like to search
    for (int t=0; t<trajectoryCount; ++t)
    {
        trajectory currentT;
        currentT.x = x;
        currentT.y = y;
        currentT.xVel = trajectories[t].xVel;
        currentT.yVel = trajectories[t].yVel;
        currentT.obsCount = 0;

        float psiSum = 0.0;
        float phiSum = 0.0;

        // Loop over each image and sample the appropriate pixel
        for (int i=0; i<imageCount; ++i)
        {
            lcArray[i] = 0;
            psiArray[i] = 0;
            phiArray[i] = 0;
            idxArray[i] = i;
            float cTime = sImgTimes[i];
            int currentX = x + int(currentT.xVel*cTime+0.5);
            int currentY = y + int(currentT.yVel*cTime+0.5);
            // Test if trajectory goes out of image bounds
            // Branching could be avoided here by setting a
            // black image border and clamping coordinates
            if (currentX >= width || currentY >= height
                || currentX < 0 || currentY < 0)
            {
                // Penalize trajctories that leave edge
                //psiSum += -0.1;
                continue;
            }
            unsigned int pixel = (pixelsPerImage*i +
                 currentY*width +
                 currentX);

            //float cPsi = psiPhiImages[pixel];
            //float cPhi = psiPhiImages[pixel+1];
            float2 cPsiPhi = reinterpret_cast<float2*>(psiPhiImages)[pixel];
            if (cPsiPhi.x == NO_DATA) continue;

            currentT.obsCount++;
            psiSum += cPsiPhi.x;// < NO_DATA/2 /*== NO_DATA* / ? 0.0 : cPsiPhi.x;//min(cPsi,0.3);
            phiSum += cPsiPhi.y;// < NO_DATA/2 /*== NO_DATA* / ? 0.0 : cPsiPhi.y;
            psiArray[i] = cPsiPhi.x;
            phiArray[i] = cPsiPhi.y;
            if (cPsiPhi.y == 0.0)
            {
                lcArray[i] = 0;
            } else {
                lcArray[i] = cPsiPhi.x/cPsiPhi.y;
            }

            //if (psiSum <= 0.0 && i>4) break;
        }
        // Just in case a phiSum is zero
        //phiSum += phiSum*1.0005+0.001;
        currentT.lh = psiSum/sqrt(phiSum);
        currentT.flux = /*2.0*fluxPix**/ psiSum/phiSum;
        // Sort the the indexes (idxArray) of lcArray
        if (currentT.lh > minLH)
        {
            for (int j = 0; j < imageCount; j++)
            {
                for (int k = j+1; k < imageCount; k++)
                {
                     if (lcArray[idxArray[j]] > lcArray[idxArray[k]])
                     {
                         tmpSortIdx = idxArray[j];
                         idxArray[j] = idxArray[k];
                         idxArray[k] = tmpSortIdx;
/*
                         tmpSortValue = lcArray[j];
                         lcArray[j] = lcArray[k];
                         lcArray[k] = tmpSortValue;

                         tmpSortValue = psiArray[j];
                         psiArray[j] = psiArray[k];
                         psiArray[k] = tmpSortValue;

                         tmpSortValue = phiArray[j];
                         phiArray[j] = phiArray[k];
                         phiArray[k] = tmpSortValue;
                         */
                     }
                }
            }
            // 25th, 50th (median), and 75 percentiles
            int minKeepIndex = 0;
            int maxKeepIndex = imageCount - 1;
            int imgCountP1 = imageCount + 1;
            const int percentiles[3] = {
                int(imgCountP1 * sGL0 + 0.5) - 1,
                int(imgCountP1 * 0.5 + 0.5) - 1,
                int(imgCountP1 * sGL1 + 0.5) - 1};
            // 0.7413 comes from the inverse of the error function
            float sigmaG = sigmaGCoeff * (lcArray[idxArray[percentiles[2]]]
                    - lcArray[idxArray[percentiles[0]]]);
            float minValue = lcArray[idxArray[percentiles[1]]] - 2 * sigmaG;
            float maxValue = lcArray[idxArray[percentiles[1]]] + 2 * sigmaG;
            for (int i = 0; i <= percentiles[1]; i++)
            {
                int idx = idxArray[i];
                if (lcArray[idx] >= minValue)
                {
                    minKeepIndex = i;
                    break;
                }
            }
            for (int i = percentiles[1]+1; i<imageCount; i++)
            {
                int idx = idxArray[i];
                if (lcArray[idx] <= maxValue)
                {
                    maxKeepIndex = i;
                } else {
                    break;
                }
            }
            float newPsiSum = 0.0;
            float newPhiSum = 0.0;
            for (int i = minKeepIndex; i < maxKeepIndex+1; i++)
            {
                int idx = idxArray[i];
                newPsiSum += psiArray[idx];
                newPhiSum += phiArray[idx];
            }
            currentT.lh = newPsiSum/sqrt(newPhiSum);
            currentT.flux = newPsiSum/newPhiSum;
        }
        trajectory temp;
        for (int r=0; r<RESULTS_PER_PIXEL; ++r)
        {
            if ( currentT.lh > best[r].lh &&
                 currentT.obsCount >= minObservations )
            {
                temp = best[r];
                best[r] = currentT;
                currentT = temp;
            }
        }
    }
    for (int r=0; r<RESULTS_PER_PIXEL; ++r)
    {
        results[ (y*width + x)*RESULTS_PER_PIXEL + r ] = best[r];
    }
    delete[] best;
}

extern "C" void
deviceSearchFilter(
        int trajCount, int imageCount, int minObservations, int psiPhiSize,
        int resultsCount, trajectory *trajectoriesToSearch, trajectory *bestTrajects,
        float *imageTimes, float *interleavedPsiPhi, int width, int height,
        float sigmaGLims[2], float sigmaGCoeff, float centralMomLims[5],
        float minLH)
{
    // Allocate Device memory
    trajectory *deviceTests;
    float *deviceImgTimes;
    float *devicePsiPhi;
    // Allocate arrays for trajectory values. Needed for light curve filtering.
    /*
    float *devicePsiArray;
    float *devicePhiArray;
    float *deviceLCArray;
    checkCudaErrors(cudaMalloc(&devicePsiArray,sizeof(float)*imageCount*trajCount));
    checkCudaErrors(cudaMalloc(&devicePhiArray,sizeof(float)*imageCount*trajCount));
    checkCudaErrors(cudaMalloc(&deviceLCArray,sizeof(float)*imageCount*trajCount));
    */
    trajectory *deviceSearchResults;

    checkCudaErrors(cudaMalloc((void **)&deviceTests, sizeof(trajectory)*trajCount));
    checkCudaErrors(cudaMalloc((void **)&deviceImgTimes, sizeof(float)*imageCount));
    checkCudaErrors(cudaMalloc((void **)&devicePsiPhi,
        sizeof(float)*psiPhiSize));
    checkCudaErrors(cudaMalloc((void **)&deviceSearchResults,
        sizeof(trajectory)*resultsCount));

    // Copy trajectories to search
    checkCudaErrors(cudaMemcpy(deviceTests, trajectoriesToSearch,
            sizeof(trajectory)*trajCount, cudaMemcpyHostToDevice));

    // Copy image times
    checkCudaErrors(cudaMemcpy(deviceImgTimes, imageTimes,
            sizeof(float)*imageCount, cudaMemcpyHostToDevice));

    // Copy interleaved buffer of psi and phi images
    checkCudaErrors(cudaMemcpy(devicePsiPhi, interleavedPsiPhi,
        sizeof(float)*psiPhiSize, cudaMemcpyHostToDevice));

    //dim3 blocks(width,height);
    dim3 blocks(width/THREAD_DIM_X+1,height/THREAD_DIM_Y+1);
    dim3 threads(THREAD_DIM_X,THREAD_DIM_Y);


    // Launch Search
    searchFilterImages<<<blocks, threads>>> (trajCount, width,
        height, imageCount, minObservations, devicePsiPhi,
        deviceTests, deviceSearchResults, deviceImgTimes, sigmaGLims[0],
        sigmaGLims[1], sigmaGCoeff, minLH);

    // Read back results
    checkCudaErrors(cudaMemcpy(bestTrajects, deviceSearchResults,
                sizeof(trajectory)*resultsCount, cudaMemcpyDeviceToHost));

    checkCudaErrors(cudaFree(deviceTests));
    checkCudaErrors(cudaFree(deviceImgTimes));
    checkCudaErrors(cudaFree(deviceSearchResults));
    checkCudaErrors(cudaFree(devicePsiPhi));
}
extern "C" void
devicePooledSetup(int imageCount, int depth, long totalPixels, float *times, int *dimensions, float *interleavedImages,
        float **deviceTimes, float **deviceImages, int **deviceDimensions)
{
    checkCudaErrors(cudaMalloc((void **)deviceTimes, sizeof(float)*imageCount));
    checkCudaErrors(cudaMalloc((void **)deviceImages, sizeof(float)*totalPixels));
    checkCudaErrors(cudaMalloc((void **)deviceDimensions, sizeof(int)*imageCount*2));

    // Copy image times
    checkCudaErrors(cudaMemcpy(*deviceTimes, times,
            sizeof(float)*imageCount, cudaMemcpyHostToDevice));

    // Copy interleaved buffer of pooled psi and phi images
    checkCudaErrors(cudaMemcpy(*deviceImages, interleavedImages,
            sizeof(float)*totalPixels, cudaMemcpyHostToDevice));

    checkCudaErrors(cudaMemcpy(*deviceDimensions, dimensions,
        sizeof(int)*imageCount*2, cudaMemcpyHostToDevice));
}

extern "C" void
devicePooledTeardown(float **deviceTimes, float **deviceImages, int **dimensions)
{
    checkCudaErrors(cudaFree(*deviceTimes));
    checkCudaErrors(cudaFree(*deviceImages));
    checkCudaErrors(cudaFree(*dimensions));
}

extern "C" void
deviceLHBatch(int imageCount, int depth, int regionCount, trajRegion *regions,
        float **deviceTimes, float **deviceImages, float **deviceDimensions)
{

}

} /* namespace kbmod */

#endif /* KERNELS_CU_ */
