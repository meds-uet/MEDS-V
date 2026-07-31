// Copyright 2026 Maktab-e-Digital Systems Lahore. SPDX-License-Identifier: Apache-2.0
// Scalar reference SAXPY:  y[i] = a*x[i] + y[i]
void saxpy_scalar(unsigned long n, float a, const float *x, float *y) {
    for (unsigned long i = 0; i < n; i++)
        y[i] = a * x[i] + y[i];
}
