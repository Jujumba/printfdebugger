#include <stdio.h>

int main() {
    printf("Debugee: Hello world!\n");
    asm("int3"); // Insert debugger breakpoint
    printf("Debugee: Hello world !\n");
    printf("Debugee: Hello world !\n");
    printf("Debugee: Hello world !\n");
}
