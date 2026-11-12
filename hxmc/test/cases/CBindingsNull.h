// The C library CBindingsNull.hx binds: NULL spans, callbacks and handles,
// and a handle's out-parameter.
struct cn_node;

int cn_sum(const int *p, int n);
int cn_apply(int (*f)(int), int v);
struct cn_node *cn_new(int v);
int cn_value(const struct cn_node *n);
int cn_child(struct cn_node *n, struct cn_node **out);
void cn_free(struct cn_node *n);
