#include <stdio.h>
#include <stdlib.h>
#include <limits.h>
#include <math.h>
#include <string>
#include <iostream>
#include <sys/time.h>
#include <opencv2/opencv.hpp>
#include <opencv2/core/core.hpp>
#include <opencv2/highgui/highgui.hpp>
#include "opencv2/cudaarithm.hpp"

#define CLUSTER_NUM       20
#define ITERATION         10

using namespace cv;
using namespace std;
using namespace cuda;

int ROWS, COLS;

__global__ void GPU_mapToCluster(unsigned char * d_label, Vec3b* d_centroids, uchar* d_image_B, uchar* d_image_G, uchar* d_image_R, int ROWS, int COLS ) {
    int col = blockIdx.x;
    int row = threadIdx.x;
    int index = COLS * row + col;
    float temp, a, b, c;
    float d = FLT_MAX;
    unsigned char cluster;
    unsigned char p1_b = d_image_B[index];
    unsigned char p1_g = d_image_G[index];
    unsigned char p1_r = d_image_R[index];
    for (unsigned char i = 0; i < CLUSTER_NUM; i++) {
        a = (float) (p1_b - d_centroids[i].val[0]);
        b = (float) (p1_g - d_centroids[i].val[1]);
        c = (float) (p1_r - d_centroids[i].val[2]);
        temp = sqrt(a*a + b*b + c*c);
        if (temp < d) {
            d = temp;
            cluster = i;
        }
    }
    d_label[index] = cluster;
}

__global__ void GPU_labelToImage (uchar* d_label, Vec3b* d_centroids, unsigned char* d_image_final_B, unsigned char* d_image_final_G, unsigned char* d_image_final_R, int COLS, int ROWS) {
    int col = blockIdx.x;
    int row = blockIdx.y;
    int color = threadIdx.x;
    int index_image = row*COLS + col;
    //int index_label = *((unsigned char*)((char*)d_label + row * pitch) + col);
    int index_label = d_label[index_image];

    switch(color) {
      case 0 :
        d_image_final_B[index_image] = d_centroids[index_label].val[0];
        break;
      case 1:
        d_image_final_G[index_image] = d_centroids[index_label].val[1];
        break;
      case 2 :
        d_image_final_R[index_image] = d_centroids[index_label].val[2];
        break;
      default :
        printf("wtf there is a bug lol\n" );
   }
}

__global__ void GPU_updateCentroid(Vec3b* d_centroids, Vec3i* d_centroids_new, int* d_count){
    int index = blockIdx.x;
    if (d_count[index] != 0) {
        d_centroids[index].val[0] = d_centroids_new[index].val[0]/d_count[index];
        d_centroids[index].val[1] = d_centroids_new[index].val[1]/d_count[index];
        d_centroids[index].val[2] = d_centroids_new[index].val[2]/d_count[index];
    }
    // resetting the values for next update
    d_count[index] = 0;
    // retardedly setting the bgr value to 0 one by one because cannot reference host methods
    d_centroids_new[index].val[0] = 0;
    d_centroids_new[index].val[1] = 0;
    d_centroids_new[index].val[2] = 0;
}

// generate a random RGB pixel as centroid
Vec3b randomPixel() {
    return Vec3b(rand()%255, rand()%255, rand()%255);
}


void updateCentroid(uchar* label, Vec3b* centroids, Mat original) {

    int cluster;
    Vec3i sum[CLUSTER_NUM];
    for (int i = 0; i < CLUSTER_NUM; i++) {
        sum[i] = Vec3i(0, 0, 0);
    }

    int count[CLUSTER_NUM] = { 0 }; // all elements 0
    for (int i = 0; i < ROWS; i++) {
        for (int j = 0; j < COLS; j++) {
            cluster = label[i*COLS + j];
            sum[cluster].val[0] += original.at<Vec3b>(i, j).val[0];
            sum[cluster].val[1] += original.at<Vec3b>(i, j).val[1];
            sum[cluster].val[2] += original.at<Vec3b>(i, j).val[2];
            count[cluster]++;
        }
    }

    for (int i = 0; i < CLUSTER_NUM; i++) {
        if (count[i] == 0) {
            continue;
        }
        sum[i].val[0] /= count[i];
        sum[i].val[1] /= count[i];
        sum[i].val[2] /= count[i];
        centroids[i] = sum[i];
    }
}

int main(int argc, char** argv)
{
    // check version c++11 or c++98
    if( __cplusplus == 201103L ) std::cout << "C++11\n" ;
    else if( __cplusplus == 199711L ) std::cout << "C++98\n" ;
    else std::cout << "pre-standard C++\n" ;

    

    printf("number of clusters: %i\n", CLUSTER_NUM);
    printf("number of iterations: %i\n", ITERATION);
    printf("mode: GPU\n");

    // start time recording
    //struct timeval stop, start;
    //gettimeofday(&start, NULL);
    
    srand(1);
    //srand(time(NULL)); //reset the random seed for this particular run
    Mat h_image, h_image_final;
    string fn = "tree";
    h_image = imread(fn + ".jpg", IMREAD_COLOR); // read the image
    if (!h_image.data) {
        printf("No image data \n");
        return -1;
    }

    ROWS = h_image.rows;
    COLS = h_image.cols;

    //printf("file: " + fn);
    printf("file size: %ix%i\n", ROWS, COLS);

    h_image_final.create(ROWS, COLS, CV_8UC1);

    // split original image to RGB
    Mat h_image_channel[3];
    split(h_image, h_image_channel);
    Mat h_image_final_channel[3];
    h_image_final_channel[0] = h_image_channel[0].clone();
    h_image_final_channel[1] = h_image_channel[1].clone();
    h_image_final_channel[2] = h_image_channel[2].clone();

    //generate random pixel for centroid

    Vec3b* h_centroids = (Vec3b*) malloc(CLUSTER_NUM * sizeof(Vec3b));
    for (int i = 0; i < CLUSTER_NUM; i++) {
        h_centroids[i] = randomPixel();
        //printf("original %i : ", i);
        //printf("%u, ", h_centroids[i].val[0]);
        //printf("%u, ", h_centroids[i].val[1]);
        //printf("%u\n", h_centroids[i].val[2]);
    }

    // generate count array to initialize to 0
    //int* h_count = (int*) malloc(CLUSTER_NUM * sizeof(int));
    //for (int i = 0; i < CLUSTER_NUM; i++) {
    //    h_count[i] = 0;
    //}

    //generate a 2D array for labelling
    uchar* h_label = (uchar *) malloc(ROWS * COLS * sizeof(uchar));

    // gpu data structure
    // --original image-- three 1D array of unsigned char for BGR
    unsigned char* d_image_B;
    unsigned char* d_image_G;
    unsigned char* d_image_R;
    cudaMalloc((void**) &d_image_B, ROWS * COLS * sizeof(unsigned char));
    cudaMalloc((void**) &d_image_G, ROWS * COLS * sizeof(unsigned char));
    cudaMalloc((void**) &d_image_R, ROWS * COLS * sizeof(unsigned char));
    cudaMemcpy(d_image_B, h_image_channel[0].data, ROWS * COLS * sizeof(unsigned char), cudaMemcpyHostToDevice);
    cudaMemcpy(d_image_G, h_image_channel[1].data, ROWS * COLS * sizeof(unsigned char), cudaMemcpyHostToDevice);
    cudaMemcpy(d_image_R, h_image_channel[2].data, ROWS * COLS * sizeof(unsigned char), cudaMemcpyHostToDevice);

    // --new image-- three 1D array of unsigned char of BGR
    unsigned char* d_image_final_B;
    unsigned char* d_image_final_G;
    unsigned char* d_image_final_R;
    cudaMalloc((void**) &d_image_final_B, ROWS * COLS * sizeof(unsigned char));
    cudaMalloc((void**) &d_image_final_G, ROWS * COLS * sizeof(unsigned char));
    cudaMalloc((void**) &d_image_final_R, ROWS * COLS * sizeof(unsigned char));

    /*
    // --labels--    2D array unsigned char on GPU
    unsigned char* d_label; 
    // variable for data structure alignment when using cudaMallocPitch
    size_t pitch_label;  
    // access method: (data type*)((char*)d_label + Row * pitch) + Column;
    cudaMallocPitch(&d_label, &pitch_label, COLS * sizeof(unsigned char), ROWS);*/

    // --labels--    1D array representing 2D array on GPU
    uchar* d_label;
    cudaMalloc((void**) &d_label, ROWS * COLS * sizeof(uchar));

    // --centroids--   1D array of unsign char on GPU
    Vec3b* d_centroids;
    cudaMalloc((void**) &d_centroids, CLUSTER_NUM * sizeof(Vec3b));

    

    // --newcentroids-- 1D array of unsign char on GPU to update centroids
    //Vec3i* d_centroids_new;
    //cudaMalloc((void**) &d_centroids_new, CLUSTER_NUM * sizeof(Vec3i));
    //cudaMemcpy(d_centroids_new, h_centroids_new, CLUSTER_NUM * sizeof(Vec3i), cudaMemcpyHostToDevice);
    // --count--        1D array of int for number of pixels in each cluster
    //int* d_count;
    //cudaMalloc((void**) &d_count, CLUSTER_NUM * sizeof(int));
    //cudaMemcpy(d_count, h_count, CLUSTER_NUM * sizeof(int), cudaMemcpyHostToDevice);

    // the real k-means
    for (int k = 0; k < ITERATION; k++) {
        // copy from host to device 
        cudaMemcpy(d_centroids, h_centroids, CLUSTER_NUM * sizeof(Vec3b), cudaMemcpyHostToDevice);

        // map all pixels to cluster
        GPU_mapToCluster<<<dim3(COLS), dim3(ROWS)>>>(d_label, d_centroids, d_image_B, d_image_G, d_image_R, ROWS, COLS);
        //cudaDeviceSynchronize();

        // update the image to the cluster colors
        GPU_labelToImage<<<dim3(COLS, ROWS), dim3(3)>>>(d_label, d_centroids, d_image_final_B, d_image_final_G, d_image_final_R, COLS, ROWS);
        //cudaDeviceSynchronize();

        // download the calculated image channels from GPU to CPU
        cudaMemcpy(h_image_final_channel[0].data, d_image_final_B, ROWS * COLS * sizeof(unsigned char), cudaMemcpyDeviceToHost);
        cudaMemcpy(h_image_final_channel[1].data, d_image_final_G, ROWS * COLS * sizeof(unsigned char), cudaMemcpyDeviceToHost);
        cudaMemcpy(h_image_final_channel[2].data, d_image_final_R, ROWS * COLS * sizeof(unsigned char), cudaMemcpyDeviceToHost);

        //Merging the new channels into image
        merge(h_image_final_channel, 3, h_image_final);
        //imwrite(fn+"/" + fn + "_gpu_fix" + to_string(k) + ".jpg",h_image_final);

        // update the centroid locations
        // download the centroids and labels back to CPU
        // cudaMemcpy(h_centroids, d_centroids, CLUSTER_NUM * sizeof(Vec3b), cudaMemcpyDeviceToHost);
        cudaMemcpy(h_label, d_label, COLS * ROWS * sizeof(unsigned char), cudaMemcpyDeviceToHost);

        updateCentroid(h_label, h_centroids, h_image);

    }
    imwrite(fn + "_gpu_fix" + ".jpg", h_image_final);
    //waitKey(0);

    // done recording time
    //gettimeofday(&stop, NULL);
    //printf("took %lu\n", stop.tv_usec - start.tv_usec);
    return 0;
}

//display image
/*
namedWindow("Iteration " + to_string(k), WINDOW_AUTOSIZE );
if(!h_image_final.empty()){
    imshow("Iteration " + to_string(k), h_image_final);
}
waitKey(0);
*/