#include <Hypervisor/Hypervisor.h>
#include <string.h>

hv_return_t mp_hv_vcpu_get_simd_fp_reg(hv_vcpu_t vcpu, uint32_t reg, uint8_t out_bytes[16]) {
    hv_simd_fp_uchar16_t val;
    hv_return_t rc = hv_vcpu_get_simd_fp_reg(vcpu, (hv_simd_fp_reg_t)reg, &val);
    if (rc == HV_SUCCESS) {
        memcpy(out_bytes, &val, 16);
    }
    return rc;
}

hv_return_t mp_hv_vcpu_set_simd_fp_reg(hv_vcpu_t vcpu, uint32_t reg, const uint8_t in_bytes[16]) {
    hv_simd_fp_uchar16_t val;
    memcpy(&val, in_bytes, 16);
    return hv_vcpu_set_simd_fp_reg(vcpu, (hv_simd_fp_reg_t)reg, val);
}

hv_return_t mp_hv_vcpu_get_reg_raw(hv_vcpu_t vcpu, uint32_t reg, uint64_t *val) {
    return hv_vcpu_get_reg(vcpu, (hv_reg_t)reg, val);
}

hv_return_t mp_hv_vcpu_set_reg_raw(hv_vcpu_t vcpu, uint32_t reg, uint64_t val) {
    return hv_vcpu_set_reg(vcpu, (hv_reg_t)reg, val);
}

hv_return_t mp_hv_vcpu_get_sys_reg_raw(hv_vcpu_t vcpu, uint16_t reg, uint64_t *val) {
    return hv_vcpu_get_sys_reg(vcpu, (hv_sys_reg_t)reg, val);
}

hv_return_t mp_hv_vcpu_set_sys_reg_raw(hv_vcpu_t vcpu, uint16_t reg, uint64_t val) {
    return hv_vcpu_set_sys_reg(vcpu, (hv_sys_reg_t)reg, val);
}
